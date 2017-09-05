#!/bin/bash -e

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
die()
{
	echo "$@" >&2
	exit 1
}

usage()
{
	echo "$0 -n <PACKAGE> -p <OBS_PROJECT> [OPTIONS]"
	echo " -n,--name            Package name in OBS"
	echo " -p,--project         Project name in OBS"
	echo " -v,--set-version     Update version in the spec file"
	echo " -g,--set-git-ver     Update git_ver in the spec file"
	echo " -R,--do-remove-tar   Remove <PACKAGE>.tar.*"
	echo " -C,--do-changes      Update the .changes file"
	echo " -b,--do-build        Build the project after updating"
	echo " -X,--pre-build=<cmd> Run <cmd> before commiting/build"
	echo " -c,--do-commit       Commit the project atfer updating"
	echo " -S,--service-only    Do not access the git but only refresh the files"
	echo " -x,--verbose         Enable verbose mode"
	echo " -h,--help            This usage"
	exit 1
}

_service_extract_param()
{
	local file=$2
	local param_name=$1
	grep $param_name $file | \
		sed -e 's/.*<param name="'$param_name'">\(.*\)<\/param>.*/\1/'
}

while [ $# -gt 0 ]; do
	opt="$1"
	shift
	case "$opt" in
		-n|--name) PACKAGE=$1; shift ;;
		-p|--project) OBS_PROJECT=$1; shift ;;
		-v|--set-version) UPDATE_VERSION=1;;
		-g|--set-git-ver) UPDATE_GITVER=1;;
		-R|--do-remove-tar) DO_REMOVE_TAR=1;;
		-C|--do-changes) DO_CHANGES=1;;
		-b|--do-build) DO_BUILD=1;;
		-X|--pre-build) PREBUILD_CMD=$1; shift;;
		-c|--do-commit) DO_COMMIT=1;;
		-S|--service-only) DO_SERVICEONLY=1;;
		-x|--verbose) set -x;;
		-h|--help) usage;;

		*) die "Unexpected option: $opt" ;;
	esac
done

if [ "$PACKAGE" == "" ]; then
	die "ERROR: PACKAGE not specified"
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
else
	if [ "$OBS_PROJECT" == "" ]; then
		die "ERROR: OBS_PROJECT not specified"
	fi
fi

if [ $DO_SERVICEONLY -ne 1 ]; then
	rm -Rf "$OBS_PROJECT/$PACKAGE"
	osc co $OBS_PROJECT $PACKAGE
	NEW_SHA=$(git rev-parse HEAD)

	# Try to fetch the rewrite patterns from the _service file
	REWRITE_PATTERN=$(_service_extract_param versionrewrite-pattern \
											 $OBS_PROJECT/$PACKAGE/_service |\
				   sed -e 's/(/\\(/' -e 's/)/\\)/')
	REWRITE_REPLACEMENT=$(_service_extract_param versionrewrite-replacement \
						  $OBS_PROJECT/$PACKAGE/_service)
	if [ "$REWRITE_PATTERN" == "" ]; then
	   #If not set, use a generic rule
	   REWRITE_PATTERN='\(.*\)'
	   REWRITE_REPLACEMENT='\1'
	fi

	MATCH_TAG=$(_service_extract_param match-tag \
									   $OBS_PROJECT/$PACKAGE/_service)
	if [ "$MATCH_TAG" != "" ]; then
		MATCH_TAG="--match $MATCH_TAG"
	fi
	VERSION=$(git describe --abbrev=0 --tags $MATCH_TAG | \
				  sed -e 's/[-:]//g' -e s/$REWRITE_PATTERN/$REWRITE_REPLACEMENT/ -e 's/-.*$//')
	OLD_SHA=$(grep revision "$OBS_PROJECT/$PACKAGE/_service"  | \
				  sed -e 's/^.*">\([0-9a-f]\{40\}\).*$/\1/')
	CHANGES=$(echo "Auto update from $OLD_SHA to $NEW_SHA";\
			  git log HEAD ^$OLD_SHA  --no-merges --format="  * %s")

	# Update service file with the proper revission
	sed -i -e 's/\(<param name="revision">\)\([0-9a-f]\{40\}\)\(<\/param>\)/\1'$NEW_SHA'\3/' "$OBS_PROJECT/$PACKAGE/_service"

	cd "$OBS_PROJECT/$PACKAGE/"
else
	VERSION=$(rpmspec -P $PACKAGE.spec  | grep Version | sed -e  's/\(Version:[[:space:]]*\)//')
	VERSION=$(rpmspec -P $PACKAGE.spec  | grep Version | sed -e  's/\(Version:[[:space:]]*\)//')
fi

# Cleanup old packages
if [ $DO_REMOVE_TAR -ne 0 ]; then
	rm -f $PACKAGE-[0-9]*.tar.gz $PACKAGE-[0-9]*.tar.bz2 $PACKAGE-[0-9]*.tar.xz
fi
LOG=$(osc service disabledrun)

# Get git suffix. This allows custom naming to work
GIT_SUFF=$(echo "$LOG" | egrep '\.tar\.(gz|xz|bz2)' | \
			   sed -e 's/.*\('$PACKAGE'[^ ]*\)\.tar\.\(gz\|xz\|bz2\).*/\1/' -e 's/'$PACKAGE'-'$VERSION'//')

if [ $UPDATE_VERSION -eq 1 ]; then
	sed -i -e 's/\(Version:[[:space:]]*\)[0-9].*/\1'$VERSION'/' $PACKAGE.spec
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
	osc commit -m "$CHANGES"
fi
