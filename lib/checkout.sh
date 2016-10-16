#!/bin/bash
# 
#   Copyright (C) 2013, 2014, 2015, 2016 Linaro, Inc
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
# 

#
# This does a checkout from a source code repository
#

# It's optional to use git-bzr-ng or git-svn to work on the remote sources,
# but we also want to work with the native source code control system.
usegit=no

# This is similar to make_all except it _just_ gathers sources trees and does
# nothing else.
checkout_all()
{
#    trace "$*"

    local packages="$*"

    for i in ${packages}; do
	local package=$i
	if test x"$i" = x"libc"; then
	    package="${clibrary}"
	fi
	if test x"${package}" = x"stage1" -o x"${package}" = x"stage2"; then
	    package="gcc"
	fi
	collect_data ${package}
	if [ $? -ne 0 ]; then
	    error "collect_data failed"
	    return 1
	fi

	local filespec="`get_component_filespec ${package}`"
	if test "`component_is_tar ${package}`" = no; then
 	    local checkout_ret=
	    checkout ${package}
	    checkout_ret=$?
	    if test ${checkout_ret} -gt 0; then
		error "Failed checkout out of ${package}."
		return 1
	    fi
	else
	    fetch ${package}
	    if test $? -gt 0; then
		error "Couldn't fetch tarball ${package}"
		return 1
	    fi
	    extract ${package}
	    if test $? -gt 0; then
		error "Couldn't extract tarball ${package}"
		return 1
	    fi
	fi

    done

    # Reset to the stored value
    if test `echo ${host} | grep -c mingw` -eq 1 -a x"${tarbin}" = xyes; then
	files="${files} installjammer-1.2.15.tar.gz"
    fi

    notice "Checkout all took ${SECONDS} seconds"

    # Set this to no, since all the sources are now checked out
    supdate=no

    return 0
}

# Try hard to get git command succeed.  Retry up to 10 times.
# $@ - arguments passed directly to "git".
git_robust()
{
    local try=1
    local cmd="git $@"

    while [ "$try" -lt "10" ]; do
	try="$(($try+1))"
	${cmd} && break
    done
}

# various black magic to forcibly update a checkout of a branch in srcdir
# uses && throughout to avoid verbose error handling
update_checkout_branch()
{
    local component="$1"
    local srcdir=
    srcdir="`get_component_srcdir ${component}`" || return 1
    notice "Updating sources for ${component} in ${srcdir}"
    dryrun "git_robust -C ${srcdir} checkout -B ${branch} origin/${branch}"
    if test $? -gt 0; then
	error "Can't checkout ${branch}"
	return 1
    fi
    dryrun "git -C ${srcdir} stash --all" &&
    dryrun "git -C ${srcdir} reset --hard" &&
    dryrun "git_robust -C ${srcdir} pull" &&
    # This is required due to the following scenario:  A git
    # reference dir is populated with a git clone on day X.  On day
    # Y a developer removes a branch and then replaces the same
    # branch with a new branch of the same name.  On day Z ABE is
    # executed against the reference dir copy and the git pull fails
    # due to error: 'refs/remotes/origin/<branch>' exists; cannot
    # create 'refs/remotes/origin/<branch>'.  You have to remove the
    # stale branches before pulling the new ones.
    dryrun "git -C ${srcdir} remote prune origin" &&

    dryrun "git_robust -C ${srcdir} pull" &&
    # Update branch directory (which maybe the same as repo
    # directory)
    dryrun "git -C ${srcdir} stash --all" &&
    dryrun "git -C ${srcdir} reset --hard"
}

update_checkout_tag()
{
    local component="$1"
    local srcdir=
    srcdir="`get_component_srcdir ${component}`" || return 1
    local branch=
    branch="`get_component_branch ${component}`" || return 1
    if git -C ${srcdir} rev-parse -q --verify origin/${branch}; then
	error "Unexpectedly not tracking origin/${branch}"
	return 1
    fi
    dryrun "git_robust -C ${srcdir} fetch"
    if test $? -gt 0; then
	error "Can't reset to ${branch}"
	return 1
    fi
    local currev="`git -C ${srcdir} rev-parse HEAD`"
    local tagrev="`git -C ${srcdir} rev-parse ${branch}`"
    if test x${currev} != x${tagrev}; then
	dryrun "git -C ${srcdir} stash && git -C ${srcdir} reset --hard ${branch}"
        if test $? -gt 0; then
	    error "Can't reset to ${branch}"
	    return 1
        fi
    fi
    return 0
}
# This gets the source tree from a remote host
# $1 - This should be a service:// qualified URL.  If you just
#       have a git identifier call get_URL first.
checkout()
{
#    trace "$*"

    local component="$1"

    # None of the following should be able to fail with the code as it is
    # written today (and failures are therefore untestable) but propagate
    # errors anyway, in case that situation changes.
    local url=
    url="`get_component_url ${component}`" || return 1
    local branch=
    branch="`get_component_branch ${component}`" || return 1
    local revision=
    revision="`get_component_revision ${component}`" || return 1
    local srcdir=
    srcdir="`get_component_srcdir ${component}`" || return 1
    local repo=
    repo="`get_component_filespec ${component}`" || return 1
    local protocol="`echo ${url} | cut -d ':' -f 1`"    
    local repodir="${url}/${repo}"
    local new_srcdir=false

    # gdbserver is already checked out in the GDB source tree.
    if test x"${component}" = x"gdbserver"; then
        local gdbsrcdir;
        gdbsrcdir="`get_component_srcdir gdb`" || return 1
        if [ x"${srcdir}" != x"${gdbsrcdir}/gdb/gdbserver" ]; then
            error "gdb and gdbserver srcdirs don't match"
            return 1
        fi
	local gdbrevision="`get_component_revision gdb`"
        if [ x"${gdbrevision}" = x"" ]; then
            error "no gdb revision found"
            return 1
        fi
	set_component_revision gdbserver ${gdbrevision}
        return 0
    fi

    dryrun "git ls-remote ${repodir} > /dev/null 2>&1"
    if test $? -ne 0; then
	error "proper URL required"
	return 1
    fi

    case ${protocol} in
	git*|http*|ssh*)
	    # If the master branch doesn't exist, clone it. If it exists,
	    # update the sources.
	    if test ! -d ${local_snapshots}/${repo}; then
		local git_reference_opt=
		if test -d "${git_reference_dir}/${repo}"; then
		    local git_reference_opt="--reference ${git_reference_dir}/${repo}"
		fi
		notice "Cloning $1 in ${local_snapshots}/${repo}"
		# Note that we are also configuring the clone to fetch gerrit
		# changes by default.  Since the git reference repos are
		# generated by this logic, most of the gerrit changes will
		# already be present in the reference.
		dryrun "git_robust clone ${git_reference_opt} --config 'remote.origin.fetch=+refs/changes/*:refs/remotes/changes/*' ${repodir} ${local_snapshots}/${repo}"
		# The above clone fetches only refs/heads/*, so fetch
		# refs/changes/* by updating the remote.
		dryrun "git -C ${local_snapshots}/${repo} remote update -p"
		if test $? -gt 0; then
		    error "Failed to clone master branch from ${url} to ${local_snapshots}/${repo}"
		    rm -f ${local_builds}/git$$.lock
		    return 1
		fi
	    fi

	    if test ! -d ${srcdir}; then
		# By definition a git commit resides on a branch.  Therefore specifying a
		# branch AND a commit is redundant and potentially contradictory.  For this
		# reason we only consider the commit if both are present.
		if test x"${revision}" != x""; then
		    notice "Checking out revision ${revision} for ${component} in ${srcdir}"
		    dryrun "${NEWWORKDIR} ${local_snapshots}/${repo} ${srcdir} ${revision}"
		    if test $? -gt 0; then
			error "Revision ${revision} likely doesn't exist in git repo ${repo}!"
			rm -f ${local_builds}/git$$.lock
			return 1
		    fi
		    # git checkout of a commit leaves the head in detached state so we need to
		    # give the current checkout a name.  Use -B so that it's only created if
		    # it doesn't exist already.
		    dryrun "git -C ${srcdir} checkout -B local_${revision}"
		    if test $? -gt 0; then
			error "Can't checkout ${revision}"
			return 1
		    fi
	        else
		    notice "Checking out branch ${branch} for ${component} in ${srcdir}"
		    dryrun "${NEWWORKDIR} ${local_snapshots}/${repo} ${srcdir} ${branch}"
		    if test $? -gt 0; then
			error "Branch ${branch} likely doesn't exist in git repo ${repo}!"
			rm -f ${local_builds}/git$$.lock
			return 1
		    fi
		fi
		new_srcdir=true
	    elif test x"${supdate}" = xyes; then
		# if we're building a particular revision, then make sure it
		# is checked out.
                if test x"${revision}" != x""; then
		    notice "Building explicit revision for ${component}."
		    # No need to pull.  A commit is a single moment in time
		    # and doesn't change.
		    dryrun "git_robust -C ${srcdir} checkout -B local_${revision} ${revision}"
		    if test $? -gt 0; then
			error "Can't checkout ${revision}"
			return 1
		    fi
		elif git -C ${srcdir} rev-parse -q --verify refs/tags/${branch}; then
		    notice "Found tag ${branch}, updating in case tag has moved."
		    update_checkout_tag "${component}"
		    if test $? -gt 0; then
			error "Error during update_checkout_tag."
			return 1
		    fi
		else
		    # Some packages allow the build to modify the source
		    # directory and that might screw up abe's state so we
		    # restore a pristine branch.
		    if test x"${branch}" = x; then
			error "No branch name specified!"
			return 1
		    fi
		    update_checkout_branch ${component}
		    if test $? -gt 0; then
			error "Error during update_checkout_branch."
			return 1
		    fi
		fi
		new_srcdir=true
	    fi

	    if test x"${dryrun}" != xyes; then
		local newrev="`git -C ${srcdir} log --format=format:%H -n 1`"
	    else
		local newrev="unknown/dryrun"
	    fi
	    set_component_revision ${component} ${newrev}
	    ;;
	*)
	    error "proper URL required"
	    return 1
	    ;;
    esac

    if test $? -gt 0; then
	error "Couldn't checkout $1 !"
	rm -f ${local_builds}/git$$.lock
	return 1
    fi

    if $new_srcdir; then
	case "${component}" in
	    gcc)
		# Touch GCC's auto-generated files to avoid non-deterministic
		# build behavior.
		dryrun "(cd ${srcdir} && ./contrib/gcc_update --touch)"
		;;
	    gdb|binutils)
		# Sometimes the timestamps are wrong after checkout causing
		# useless rebuilds. In the case of intl/plural.[cy], it's
		# causing build failures because plural.y is very old, and the
		# file generated by a modern bison cannot be compiled. The
		# clean fix would be to merge intl/ with newer gettext in
		# binutils-gdb. Quick hack: force plural.c to be more recent
		# than plural.y.
		dryrun "touch ${srcdir}/intl/plural.c"
		;;
	esac
    fi

    rm -f ${local_builds}/git$$.lock
    return 0
}

# This pushes a source tree up to a remote host. For bzr and git, any changes
# that should be uploaded to the remote source repository need to be commit()'d
# first. For svn and cvs, this push does a commit instead.
# $1 - The URL to push to, same as used for checkout
# $2 - The optional host to push to
# $3 - The optional branch to push to
push ()
{
    if test x"$1" = x; then
	error "No URL given!"
	return 1
    fi
    if test x"$2" = x; then
	warning "No host given, so using origin"
	local repo="origin"
    fi

    # bzr uses slashes in it's path names, so convert them so we
    # can use the for accessing the source directory.
    local url="`echo $1 | sed -e 's:/:_:'`"
    local dir="`basename ${url} |sed -e 's/^.*://'`"

    # We use git for our copy by importing from the other systems
    case $1 in
	git*|ssh*)
	    if test x"$3" = x; then
		warning "No branch given, so using master or trunk"
		local branch="master"
	    fi
	    if test -e ${local_snapshots}/${dir}/.git; then
		#out="`git -C ${local_snapshots}/${dir} push ${repo} ${branch}`"
		notice "Pushing ${dir} upstream"
		notice "git push ${repo} ${branch}"
	    else
		error "${local_snapshots}/${dir} doesn't exist!"
		return 1
	    fi
	    ;;
	*)
	    ;;
    esac

    return 0
}

# This commits a change to a source tree. For bzr and git, this only
# modifies the local source tree, and push() must be executed to actually
# upload the changes to the remote source tree. For svn and cvs, the
# commit modifies the remote sources at the same time.
# $1 - The URL used for checkout()
# $2 - the file or directory to commit
commit ()
{
    # bzr uses slashes in it's path names, so convert them so we
    # can use the for accessing the source directory.
    local url="`echo $1 | sed -e 's:/:_:'`"
    local dir="`basename ${url} |sed -e 's/^.*://'`"

    # We use git for our copy by importing from the other systems
    case $1 in
	git*|ssh*)
	    if test x"$2" = x; then
		warning "No files given, so commiting all"
		local files="-a"
	    else
		local files="$2"
	    fi
	    if test -e ${local_snapshots}/${dir}/.git; then
		#out="`git -C ${local_snapshots}/${dir} commit --file ${local_snapshots}/${dir}/commitmsg.txt ${files}`"
		notice "Committing ${files} to local repository..."
		notice "git commit -m \"`cat ${local_snapshots}/${dir}/commitmsg.txt`\" ${files}"
   	    else
		error "${local_snapshots}/${dir} doesn't exist!"
		return 1
	    fi
	    ;;
	*)
	    ;;
    esac

    return 0
}

# Create a new tag in a repository
# $1 - The URL used for checkout()
# $2 - the tag name
tag()
{
    error "unimplemented"
}

# Change the active branch.
# FIXME: for now, this only supports git.
#
# $1 - The toolchain component to use, which looks like this:
# gcc.git/linaro-4.8-branch@123456
# Which breaks down as gcc.git is the component name. Anything after a slash
# is the branch. Anything after a '@' is a GIT commit hash ID.
change_branch()
{
#    trace "$*"

    local version="`basename $1`"
    local branch="`echo $1 | cut -d '/' -f 2`"

    local srcdir="`get_component_srcdir $1`"
    if test "`echo $1 | grep -c '@'`" -gt 0; then
	local revision="`echo $1 | cut -d '@' -f 2`"
    else
	local revision=""
    fi

    if test ! -d ${srcdir}/${branch}; then
	local cmd="${NEWWORKDIR} ${local_snapshots}/${version} ${local_snapshots}/${version}-${branch} ${branch}"
	dryrun "${cmd}"
    else
	if test x"${supdate}" = xyes; then
	    if test x"${branch}" = x; then
		dryrun "git_robust -C ${local_snapshots}/${version} pull origin master"
	    else
		dryrun "git_robust -C ${local_snapshots}/${version}-${branch} pull origin ${branch}"
	    fi
	fi
    fi
    
    return 0
}

