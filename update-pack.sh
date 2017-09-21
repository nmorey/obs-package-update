#!/bin/bash -e

VERBOSE=0
OBS_PROJECT=""
PACKAGE=""
UPDATE_VERSION=0
UPDATE_GITVER=0
DO_REMOVE_TAR=0
DO_CHANGES=0
DO_BUILD=0
PREBUILD_CMDT=""
DO_COMMIT=0
DO_SERVICEONLY=0
TARBALL_NAME=""
DO_GIT_VERSION_EXTRACT=0
VERSION_NAME=""
_VERSION_NAME=""
MAJOR_NAME=""

die()
{
	echo "$@" >&2
	exit 1
}

_service_extract_param()
{
	local file=$2
	local param_name=$1
	grep $param_name $file | \
		sed -e 's/.*<param name="'$param_name'">\(.*\)<\/param>.*/\1/'
}

_get_git_version()
{
	REPLACE_CHAR=''
	if [ $DO_GIT_VERSION_EXTRACT -ne 0 ]; then
		REPLACE_CHAR="."
	fi
	git describe --abbrev=0 --tags $MATCH_TAG | \
		sed -e 's/[-:]/'$REPLACE_CHAR'/g' \
			-e s/$REWRITE_PATTERN/$REWRITE_REPLACEMENT/ -e 's/[^0-9.].*$//'
}
_get_git_full_version()
{
	REPLACE_CHAR=''
	if [ $DO_GIT_VERSION_EXTRACT -ne 0 ]; then
		REPLACE_CHAR="."
	fi
	git describe  --tags $MATCH_TAG | \
		sed -e 's/[-:]/'$REPLACE_CHAR'/g' \
			-e s/$REWRITE_PATTERN/$REWRITE_REPLACEMENT/
}

usage()
{
	echo "$0 -n <PACKAGE> -p <OBS_PROJECT> [OPTIONS]"
	echo " -n,--name                  Package name in OBS"
	echo " -p,--project               Project name in OBS"
	echo " -T,--tar-name              Tarball name (except version). Defaults to package name"
	echo " -v,--set-version           Update version in the spec file"
	echo "    --version-name <str>    Replace define 'str' instead of global Version:"
	echo "    --_version-name <str>   Set define <str> to clean version string (package name compatible)"
	echo "    --major-name <str>      Set define <str> to the major version"
	echo " -g,--set-git-ver           Update git_ver in the spec file"
	echo " -G,--do-git-version        Extract version from git and update _service (default gets from service results"
	echo " -R,--do-remove-tar         Remove <PACKAGE>.tar.*"
	echo " -C,--do-changes            Update the .changes file"
	echo " -b,--do-build              Build the project after updating"
	echo " -X,--pre-build=<cmd>       Run <cmd> before commiting/build"
	echo " -c,--do-commit             Commit the project atfer updating"
	echo " -S,--service-only          Do not access the git but only refresh the files"
	echo " -x,--verbose               Enable verbose mode"
	echo " -h,--help                  This usage"
	exit 1
}

while [ $# -gt 0 ]; do
	opt="$1"
	shift
	case "$opt" in
		-n|--name) PACKAGE=$1; shift ;;
		-p|--project) OBS_PROJECT=$1; shift ;;
		-T|--tar-name) TARBALL_NAME=$1; shift ;;
		-v|--set-version) UPDATE_VERSION=1;;
		--version-name) VERSION_NAME=$1; shift;;
		--_version-name) _VERSION_NAME=$1; shift;;
		--major-name) MAJOR_NAME=$1; shift;;
		-g|--set-git-ver) UPDATE_GITVER=1;;
		-G|--do-git-version) DO_GIT_VERSION_EXTRACT=1;;
		-R|--do-remove-tar) DO_REMOVE_TAR=1;;
		-C|--do-changes) DO_CHANGES=1;;
		-b|--do-build) DO_BUILD=1;;
		-X|--pre-build) PREBUILD_CMD=$1; shift;;
		-c|--do-commit) DO_COMMIT=1;;
		-S|--service-only) DO_SERVICEONLY=1;;
		-x|--verbose) VERBOSE=1;;
		-h|--help) usage;;

		*) die "Unexpected option: $opt" ;;
	esac
done

if [ $VERBOSE -ne 0 ]; then
	set -x
fi
if [ "$PACKAGE" == "" ]; then
	if [ -f .osc/_package ]; then
		PACKAGE=$(cat .osc/_package)
	fi
	if [ "$PACKAGE" == "" ]; then
		die "ERROR: PACKAGE not specified"
	fi
fi
if [ $DO_SERVICEONLY -eq 1 ]; then
   if [ $UPDATE_VERSION -eq 1 ]; then
	   die "Cannot run service only and request version update"
   fi
   if [ $DO_CHANGES -eq 1 ]; then
	   die "Cannot run service only and do changelog"
   fi
   if [ $DO_COMMIT -eq 1 ]; then
	   die "Cannot run service only and commit"
   fi
   if [ $DO_GIT_VERSION_EXTRACT -eq 1 ]; then
	   die "Cannot run service only and extract version from git"
   fi
else
	if [ "$OBS_PROJECT" == "" ]; then
		die "ERROR: OBS_PROJECT not specified"
	fi
fi

if [ "$TARBALL_NAME" == "" ]; then
	TARBALL_NAME=$PACKAGE
fi

if [ $DO_SERVICEONLY -ne 1 ]; then
	# Get version from git
	osc co $OBS_PROJECT $PACKAGE || true
	(cd $OBS_PROJECT/$PACKAGE && osc up )

	# Try to fetch the rewrite patterns from the _service file
	export REWRITE_PATTERN=$(_service_extract_param versionrewrite-pattern \
													$OBS_PROJECT/$PACKAGE/_service |\
								 sed -e 's/(/\\(/' -e 's/)/\\)/')
	export REWRITE_REPLACEMENT=$(_service_extract_param versionrewrite-replacement \
														$OBS_PROJECT/$PACKAGE/_service)
	if [ "$REWRITE_PATTERN" == "" ]; then
		#If not set, use a generic rule
		REWRITE_PATTERN='\(.*\)'
		REWRITE_REPLACEMENT='\1'
	fi

	export MATCH_TAG=$(_service_extract_param match-tag $OBS_PROJECT/$PACKAGE/_service)
	if [ "$MATCH_TAG" != "" ]; then
		MATCH_TAG="--match $MATCH_TAG"
	fi

	VERSION=$(_get_git_version)
	NEW_SHA=$(git rev-parse HEAD)
	OLD_SHA=$(grep revision "$OBS_PROJECT/$PACKAGE/_service"  | \
				  sed -e 's/^.*">\([0-9a-f]\{40\}\).*$/\1/')
	CHANGES=$(echo "Auto update from $OLD_SHA to $NEW_SHA";\
			  git log HEAD ^$OLD_SHA  --no-merges --format="  * %s")

	# Update service file with the proper revission
	sed -i -e 's/\(<param name="revision">\)\([0-9a-f]\{40\}\)\(<\/param>\)/\1'$NEW_SHA'\3/'\
		"$OBS_PROJECT/$PACKAGE/_service"


	if [ $DO_GIT_VERSION_EXTRACT -ne 0 ]; then
		# We need to bump the version name of the package
		# Probably to avoid the service screwing up weird tags with - in them
		FULL_VERSION=$(_get_git_full_version)
		# Update version in the service file
		sed -i -e 's/\(<param name="version">\).*\(<\/param>\)/\1'$FULL_VERSION'\2/' \
			"$OBS_PROJECT/$PACKAGE/_service"

	fi
	cd "$OBS_PROJECT/$PACKAGE/"
else
	#Get version from spec and suffix later on from _service result
	VERSION=$(rpmspec -P $PACKAGE.spec  | grep Version: | sed -e  's/\(Version:[[:space:]]*\)//')
fi

# Cleanup old packages
if [ $DO_REMOVE_TAR -ne 0 ]; then
	rm -f $TARBALL_NAME-[0-9]*.tar.gz $TARBALL_NAME-[0-9]*.tar.bz2 $TARBALL_NAME-[0-9]*.tar.xz
fi
LOG=$(osc service disabledrun)

# Get git suffix. This allows custom naming to work
GIT_SUFF=$(echo "$LOG" | egrep '\.tar\.(gz|xz|bz2)' | head -n 1 | \
			   sed -e 's/.*\('$TARBALL_NAME'[^ ]*\)\.tar\.\(gz\|xz\|bz2\).*/\1/' -e 's/'$TARBALL_NAME'-'$VERSION'//')
if [ "$GIT_SUFF" == "" ]; then
	GIT_SUFF="%{nil}"
fi

if [ $UPDATE_VERSION -eq 1 ]; then
	if [ "$VERSION_NAME" == "" ]; then
		sed -i -e 's/\(Version:[[:space:]]*\)[0-9].*/\1'$VERSION'/' $PACKAGE.spec
	else
		sed -i -e 's/\($define '$VERSION_NAME'[[:space:]]*\)[0-9].*/\1'$VERSION'/' $PACKAGE.spec
	fi
	if [ "$_VERSION_NAME" != "" ]; then
		_VERSION=$(echo $VERSION | sed -e 's/\./_/g')
		sed -i -e 's/\($define '$_VERSION_NAME'[[:space:]]*\)[0-9].*/\1'$_VERSION'/' $PACKAGE.spec
	fi
	if [ "$MAJOR_NAME" != "" ]; then
		MAJOR_VERSION=$(echo $VERSION | awk -F ',' '{ print $1}')
		sed -i -e 's/\($define '$MAJOR_NAME'[[:space:]]*\)[0-9].*/\1'$MAJOR_VERSION'/' $PACKAGE.spec
	fi
fi
if [ $UPDATE_GITVER -eq 1 ]; then
	sed -i -e 's/\(%define[[:space:]]*git_ver\).*/\1 '$GIT_SUFF'/' $PACKAGE.spec
fi

# Update file index for osc
osc addremove

if [ $DO_CHANGES -ne 0 ]; then
	osc vc -m "$CHANGES" $PACKAGE.changes
fi
if [ "$PREBUILD_CMD" != "" ]; then
	$PREBUILD_CMD
fi
if [ $DO_BUILD -ne 0 ]; then
	osc build --trust-all-projects --clean
fi
if [ $DO_COMMIT -ne 0 ]; then
	N_LINES=$(echo "$CHANGES" | wc -l)
	if [ $N_LINES -ge 10 ]; then
		COMMIT_LOG=$(echo "$CHANGES" | head -n 10; echo '[...]')
	else
		COMMIT_LOG=$CHANGES
	fi
	osc commit -m "$COMMIT_LOG"
fi
