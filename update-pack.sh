#!/bin/bash -e

OBS_PROJECT=""
PACKAGE=""
UPDATE_VERSION=0
UPDATE_GITVER=0
DO_BUILD=0
DO_COMMIT=0

die()
{
	echo "$@" >&2
	exit 1
}

usage()
{
	echo "$0 -n <PACKAGE> -p <OBS_PROJECT>"
	echo " -n,--name       Package name in OBS"
	echo " -p,--project    Project name in OBS"
	echo " -v              Update version in the spec file"
	echo " -g              Update git_ver in the spec file"
	echo " -b              Build the project atfer updating"
	echo " -c              Commit the project atfer updating"
	echo " -h,--help       This usage"
	exit 1
}
while [ $# -gt 0 ]; do
	opt="$1"
	shift
	case "$opt" in
		-n|--name) PACKAGE=$1; shift ;;
		-p|--project) OBS_PROJECT=$1; shift ;;
		-h|--help) usage;;
		-v) UPDATE_VERSION = 1;;
		-g) UPDATE_GITVER = 1;;
		*) die "Unexpected option: $opt" ;;
	esac
done

if [ "$OBS_PROJECT" == "" ]; then
	die "ERROR: OBS_PROJECT not specified"
fi
if [ "$PACKAGE" == "" ]; then
	die "ERROR: PACKAGE not specified"
fi

cd $WORKSPACE;
PACKAGE=libfabric

rm -Rf "$OBS_PROJECT/$PACKAGE"
osc co $OBS_PROJECT $PACKAGE
NEW_SHA=$(git rev-parse HEAD)
VERSION=$(git describe --abbrev=0 | sed -e 's/^v//' -e 's/-.*$//')
OLD_SHA=$(grep revision "$OBS_PROJECT/$PACKAGE/_service"  | \
			  sed -e 's/^.*">\([0-9a-f]\{40\}\).*$/\1/')
CHANGES=$(echo "Auto update from $OLD_SHA to $NEW_SHA";\
		  git log HEAD ^$OLD_SHA  --no-merges --format="  * %s")

# Update service file with the proper revission
sed -i -e 's/\(<param name="revision">\)\([0-9a-f]\{40\}\)\(<\/param>\)/\1'$NEW_SHA'\3/' "$OBS_PROJECT/$PACKAGE/_service"

cd "$OBS_PROJECT/$PACKAGE/"
# Cleanup old packages
rm -f $PACKAGE-[0-9]*.tar.gz $PACKAGE-[0-9]*.tar.bz2 $PACKAGE-[0-9]*.tar.xz
LOG=$(osc service disabledrun)

# Get git suffix. This allows custom naming to work
GIT_SUFF=$(echo "$LOG" | egrep '\.tar\.(gz|xz|bz2)' | \
			   sed -e 's/.*\('$PACKAGE'[^ ]*\)\.tar\.\(gz\|xz\|bz2\).*/\1/' -e 's/'$PACKAGE'-[0-9]*//')

if [ $UPDATE_VERSION -eq 1 ]; then
	sed -i -e 's/\(Version:[[:space:]]*\)[0-9].*/\1'$VERSION'/' $PACKAGE.spec
fi
if [ $UPDATE_GITVER -eq 1 ]; then
	sed -i 's/\(%define[[:space:]]*git_ver\).*/\1 '$GIT_SUFF'/' -e $PACKAGE.spec
fi

osc addremove
osc vc -m "$CHANGES" $PACKAGE.changes
if [ $DO_BUILD -eq 1 ]; then
	osc build --trust-all-projects --clean
fi
if [ $DO_COMMIT -eq 1 ]; then
	osc commit -m "$CHANGES"
fi
