runMakefiles ()
{
	makeParams=install
	if [[ "$@" ]]
	then
		makeParams=$@
	fi
	echo "Make parameters: $makeParams"
	for makefile in $makefilesToRun
	do
		oldDir=`pwd`
		cd `dirname $makefile`
		echo "Running makefile: $makefile"
		make -j4 -f `basename $makefile` $makeParams
		if [ $? != 0 ]
		then
			exit 1
		fi
		cd $oldDir
	done
}

