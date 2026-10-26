/*  This file is part of EmuFramework.

	Imagine is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	Imagine is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with EmuFramework.  If not, see <http://www.gnu.org/licenses/> */

#include <emuframework/EmuSystemTask.hh>
#include <emuframework/EmuApp.hh>
import imagine;

namespace EmuEx
{

using namespace IG;

constexpr SystemLogger log{"EmuSystemTask"};

EmuSystemTask::EmuSystemTask(EmuApp& app_):
	app{app_},
	onFrameUpdate
	{
		[this](FrameParams params)
		{
			bool renderingFrame = advanceFrames(params);
			if(params.isFromRenderer() && !renderingFrame)
			{
				drawWindowNow();
			}
			return true;
		}
	} {}

void EmuSystemTask::start(Window& win)
{
	if(isStarted())
		return;
	win.removeFrameEvents();
	win.setDrawEventEnabled(false); // block UI from posting draws
	shouldWaitForPresent = app.lowLatencyVideo && app.effectiveFrameClockSource() != FrameClockSource::Renderer;
	setWindowInternal(win);
	taskThread = makeThreadSync(
		[this](auto &sem)
		{
			auto threadId = thisThreadId();
			threadId_ = threadId;
			auto eventLoop = EventLoop::makeForThread();
			window().setFrameEventsOnThisThread();
			addOnFrameDelayed();
			bool started = true;
			commandPort.attach(eventLoop, [this, &started](auto msgs)
			{
				for(auto msg : msgs)
				{
					bool threadIsRunning = msg.command.visit(overloaded
					{
						[&](SetWindowCommand& cmd)
						{
							//log.debug("got set window command");
							isSuspended = true;
							removeOnFrame();
							setWindowInternal(*cmd.winPtr);
							addOnFrame();
							msg.semPtr->release();
							suspendSem.acquire();
							return true;
						},
						[&](SuspendCommand&)
						{
							//log.debug("got suspend command");
							isSuspended = true;
							msg.semPtr->release();
							suspendSem.acquire();
							return true;
						},
						[&](ExitCommand&)
						{
							started = false;
							removeOnFrame();
							window().removeFrameEvents();
							threadId_ = 0;
							frameRateConfig = {};
							EventLoop::forThread().stop();
							return false;
						},
					});
					if(!threadIsRunning)
						return false;
				}
				return true;
			});
			sem.release();
			log.info("starting emulation thread:{}, sync present:{}", threadId, shouldWaitForPresent);
			eventLoop.run(started);
			log.info("exiting emulation thread:{}", threadId);
			commandPort.detach();
		});
}

EmuSystemTask::SuspendContext EmuSystemTask::setWindow(Window& win)
{
	assume(!isSuspended);
	if(!isStarted())
		return {};
	commandPort.send({.command = SetWindowCommand{&win}}, MessageReplyMode::wait);
	return {this};
}

void EmuSystemTask::setWindowInternal(Window& win)
{
	winPtr = &win;
	updateSystemFrameRate();
}

void EmuSystemTask::drawWindowNow()
{
	bool shouldWait = setWaitForPresent();
	window().drawNow();
	if(shouldWait)
	{
		framePresentedSem.acquire();
	}
}

EmuSystemTask::SuspendContext EmuSystemTask::suspend()
{
	if(!isStarted() || isSuspended)
		return {};
	//log.info("suspending emulation thread");
	commandPort.send({.command = SuspendCommand{}}, MessageReplyMode::wait);
	return {this};
}

void EmuSystemTask::resume()
{
	if(!isStarted() || !isSuspended)
		return;
	//log.info("resuming emulation thread");
	isSuspended = false;
	suspendSem.release();
}

void EmuSystemTask::stop()
{
	if(!isStarted())
		return;
	if(Config::DEBUG_BUILD)
	{
		auto threadId = thisThreadId();
		log.info("request stop emulation thread:{} from:{}", threadId_, threadId);
		assume(threadId_ != thisThreadId());
	}
	commandPort.send({.command = ExitCommand{}});
	taskThread.join();
	app.flushMainThreadMessages();
	winPtr->setFrameEventsOnThisThread();
	winPtr->setDrawEventEnabled(true); // allow UI to post draws again
	winPtr->setIntendedFrameRate(0);
	winPtr = {};
}

void EmuSystemTask::sendVideoFormatChangedReply(EmuVideo&)
{
	app.videoLayer.onVideoFormatChanged(app.videoEffectPixelFormat());
	app.viewController().placeEmuViews();
}

void EmuSystemTask::sendFrameFinishedReply(EmuVideo&)
{
	window().drawNow();
}

void EmuSystemTask::sendScreenshotReply(bool success)
{
	app.runOnMainThread([&app = app, success](ApplicationContext)
	{
		app.printScreenshotResult(success);
	});
}

OnFrameDelegate EmuSystemTask::onFrameCalibrate()
{
	return [this](FrameParams params)
	{
		if(app.system().frameRateMultiplier != 1.)
			return true;
		frameRateDetector.addFrame(params);
		if(frameRateDetector.hasConsistentRate())
		{
			FrameRate detectedRate{frameRateDetector.estimatedFrameDuration()};
			log.debug("detected frame duration:{} ({}Hz)", detectedRate.duration(), detectedRate.hz());
			detectedFrameRateMap[frameRateDetector.frameDuration()] = detectedRate;
			configFrameRate(detectedRate);
			return false;
		}
		constexpr int maxFramesToProcess = 4096;
		if(frameRateDetector.framesCounted() >= maxFramesToProcess)
		{
			log.warn("unable to detect frame rate");
			return false;
		}
		return true;
	};
}

OnFrameDelegate EmuSystemTask::onFrameDelayed(uint16_t delay)
{
	return [this, delay](FrameParams params)
	{
		if(params.isFromRenderer() || app.video.image())
		{
			drawWindowNow();
		}
		if(delay)
		{
			addOnFrameDelegate(onFrameDelayed(delay - 1));
		}
		else
		{
			addOnFrame();
		}
		return false;
	};
}

void EmuSystemTask::addOnFrameDelegate(OnFrameDelegate onFrame)
{
	window().addOnFrame(onFrame, window().toFrameClockMode(app.frameClockSource, FrameClockUsage::fixedRate));
}

void EmuSystemTask::addOnFrameDelayed()
{
	auto screenRate = screen().frameRate();
	calibrateScreenFrameRate(screenRate);
	// delay before adding onFrame handler to let timestamps stabilize
	addOnFrameDelegate(onFrameDelayed(screenRate.hz() / 4));
}

void EmuSystemTask::addOnFrame()
{
	addOnFrameDelegate(onFrameUpdate);
	savedAdvancedFrames = 0;
}

void EmuSystemTask::removeOnFrame()
{
	auto mode = window().toFrameClockMode(app.frameClockSource, FrameClockUsage::fixedRate);
	window().removeOnFrame(onFrameDelayed(0), mode, DelegateFuncEqualsMode::byFunc);
	window().removeOnFrame(onFrameUpdate, mode);
	window().removeOnFrame(onFrameCalibrate(), FrameClockMode::screen);
}

FrameRate EmuSystemTask::remapScreenFrameRate(FrameRate rate) const
{
	return doIfUsedOr(detectedFrameRateMap, [&](auto& map)
	{
		if(app.effectiveOutputFrameRateMode() == OutputFrameRateMode::Detect)
		{
			auto it = map.find(rate.duration());
			if(it != map.end())
				return it->second;
		}
		return rate;
	},
	[&]()
	{
		if(app.effectiveOutputFrameRateMode() == OutputFrameRateMode::Detect &&
			frameRateDetector.frameDuration() == rate.duration() &&
			frameRateDetector.hasConsistentRate())
		{
			return FrameRate{frameRateDetector.estimatedFrameDuration()};
		}
		return rate;
	});
}

FrameRateConfig EmuSystemTask::configFrameRate(const Screen& screen)
{
	if(app.overrideScreenFrameRate)
	{
		return configFrameRate(remapScreenFrameRate(app.overrideScreenFrameRate));
	}
	else if(app.effectiveOutputFrameRateMode() == OutputFrameRateMode::Detect)
	{
		if constexpr(Config::multipleScreenFrameRates)
		{
			auto rates = screen.supportedFrameRates();
			FrameRate ratesCopy[rates.size()];
			transformN(rates.data(), rates.size(), ratesCopy, [&](auto& r) { return remapScreenFrameRate(r); });
			return configFrameRate(std::span{ratesCopy, rates.size()});
		}
		else
		{
			return configFrameRate(remapScreenFrameRate(screen.frameRate()));
		}
	}
	else
	{
		return configFrameRate(screen.supportedFrameRates());
	}
}

FrameRateConfig EmuSystemTask::configFrameRate(std::span<const FrameRate> supportedRates)
{
	auto &system = app.system();
	auto frameClockSrc = app.effectiveFrameClockSource();
	frameRateConfig = app.outputTimingManager.frameRateConfig(system, supportedRates, frameClockSrc);
	system.configFrameRate(app.audio.format().rate, frameRateConfig.rate.duration());
	system.timing.exactFrameDivisor = 0;
	if(frameRateConfig.refreshMultiplier > 0 && (app.allowBlankFrameInsertion || !app.frameInterval))
	{
		system.timing.exactFrameDivisor = frameClockSrc == FrameClockSource::Timer ? 1 : frameRateConfig.refreshMultiplier;
	}
	if(system.timing.exactFrameDivisor)
		log.info("using exact frame divisor:{}", system.timing.exactFrameDivisor);
	return frameRateConfig;
}

void EmuSystemTask::updateScreenFrameRate(FrameRate rate)
{
	if(!winPtr) [[unlikely]]
		return;
	calibrateScreenFrameRate(rate);
	configFrameRate(remapScreenFrameRate(rate));
}

void EmuSystemTask::updateSystemFrameRate()
{
	if(!winPtr) [[unlikely]]
		return;
	setIntendedFrameRate(configFrameRate(screen()));
}

void EmuSystemTask::calibrateScreenFrameRate(FrameRate rate)
{
	if(!app.system().isActive() ||
		window().evalFrameClockSource(app.frameClockSource, FrameClockUsage::fixedRate) != FrameClockSource::Screen ||
		app.effectiveOutputFrameRateMode() != OutputFrameRateMode::Detect ||
		doIfUsed<bool>(detectedFrameRateMap, [&](auto& map){ return map.contains(rate.duration()); }) ||
		!frameRateDetector.setFrameDuration(rate.duration()))
	{
		window().removeOnFrame(onFrameCalibrate(), FrameClockMode::screen);
	}
	else
	{
		log.info("performing host frame rate detection for screen rate:{}Hz", rate.hz());
		window().addOnFrame(onFrameCalibrate(), FrameClockMode::screen, -1, InsertMode::unique);
	}
}

void EmuSystemTask::setIntendedFrameRate(FrameRateConfig config)
{
	enableBlankFrameInsertion = false;
	if(app.allowBlankFrameInsertion && config.refreshMultiplier > 1 && app.frameInterval <= 1)
	{
		enableBlankFrameInsertion = true;
		if(!app.overrideScreenFrameRate)
		{
			config.rate = config.rate.hz() * config.refreshMultiplier;
			log.info("Multiplied intended frame rate to:{:g}", config.rate.hz());
		}
	}
	window().setIntendedFrameRate(app.overrideScreenFrameRate ? FrameRate{app.overrideScreenFrameRate} :
		app.effectiveFrameClockSource() == FrameClockSource::Timer || config.refreshMultiplier ? config.rate :
		screen().supportedFrameRates().back()); // frame rate doesn't divide evenly in screen's refresh rate, prefer the highest rate
}

bool EmuSystemTask::advanceFrames(FrameParams frameParams)
{
	assume(hasTime(frameParams.time));
	auto &sys = app.system();
	auto &viewCtrl = app.viewController();
	auto *audioPtr = app.audio ? &app.audio : nullptr;
	auto frameInfo = sys.timing.advanceFrames(frameParams);
	int interval = app.frameInterval;
	if(shouldWaitForPresent)
	{
		viewCtrl.presentTime = frameParams.presentTime(interval);
	}
	if(sys.shouldFastForward()) [[unlikely]]
	{
		// for skipping loading on disk-based computers
		if(sys.skipForwardFrames({this}, 20))
		{
			// don't write any audio while skip is in progress
			audioPtr = nullptr;
		}
		frameInfo.advanced = 1;
	}
	if(!frameInfo.advanced)
	{
		if(enableBlankFrameInsertion)
		{
			viewCtrl.drawBlankFrame = true;
			drawWindowNow();
			return true;
		}
		return false;
	}
	bool allowFrameSkip = interval || sys.frameRateMultiplier != 1.;
	if(frameInfo.advanced + savedAdvancedFrames < interval)
	{
		// running at a lower target fps
		savedAdvancedFrames += frameInfo.advanced;
	}
	else
	{
		savedAdvancedFrames = 0;
		if(!allowFrameSkip)
		{
			frameInfo.advanced = 1;
		}
		if(frameInfo.advanced > 1 && frameParams.elapsedFrames() > 1)
		{
			if(sys.frameRateMultiplier == 1.)
			{
				app.frameTimingStats.missedFrameCallbacks += frameInfo.advanced - 1;
			}
			viewCtrl.presentTime = {};
		}
	}
	assume(frameInfo.advanced > 0);
	// cap advanced frames if we're falling behind (max 2 on single-core Cortex-A9 to prevent UI/input thread starvation)
	frameInfo.advanced = std::min(frameInfo.advanced, 2);
	EmuVideo *videoPtr = savedAdvancedFrames ? nullptr : &app.video;
	bool shouldWait{};
	if(videoPtr)
	{
		app.record(FrameTimingStatEvent::startOfFrame, frameParams.time);
		app.record(FrameTimingStatEvent::startOfEmulation);
		shouldWait = setWaitForPresent();
	}
	//log.debug("running {} frame(s), skip:{}", frameInfo.advanced, !videoPtr);
	sys.runFrames({this}, videoPtr, audioPtr, frameInfo.advanced);
	app.inputManager.turboActions.update(app);
	if(!videoPtr)
		return false;
	app.record(FrameTimingStatEvent::waitForPresent);
	if(shouldWait)
	{
		framePresentedSem.acquire();
	}
	auto endFrameTime = SteadyClock::now();
	app.reportFrameWorkDuration(endFrameTime - frameParams.time);
	app.record(FrameTimingStatEvent::endOfFrame, endFrameTime);
	viewCtrl.emuView.setFrameTimingStats({.stats{app.frameTimingStats}, .lastFrameTime{frameParams.lastTime},
		.inputRate{sys.frameRate()}, .outputRate{frameRateConfig.rate}});
	return true;
}

void EmuSystemTask::notifyWindowPresented()
{
	if(waitingForPresent_)
	{
		waitingForPresent_ = false;
		framePresentedSem.release();
	}
}

bool FrameRateDetector::addFrame(FrameParams params)
{
	if(!hasTime(params.lastTime))
	{
		return false;
	}
	auto delta = params.delta();
	if(!isWithinThreshold(delta.count(), frameDuration_.count(), Nanoseconds{200000}.count()))
	{
		//log.debug("filtered delta:{} ({}Hz)", delta, toHz(delta));
		return false;
	}
	auto prevEstimate = frameDurations ? estimatedFrameDuration() : SteadyClockDuration{};
	allFrameDurations += delta;
	frameDurations++;
	auto estimate = estimatedFrameDuration();
	if(isWithinThreshold(prevEstimate.count(), estimate.count(), Nanoseconds{16}.count()))
	{
		consistentDurations++;
		//log.debug("consistent frame durations:{}", consistentDurations);
	}
	else
	{
		consistentDurations = {};
	}
	return true;
}

}
