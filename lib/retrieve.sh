#!/bin/bash
# 
#   Copyright (C) 2013, 2014, 2015, 2016, 2017 Linaro, Inc
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
# This retrieves source code from the remote server(s).
#

# This is similar to make_all except it _just_ gathers sources trees and does
# nothing else.
retrieve_all()
{
#    trace "$*"

    local packages="$*"

    notice "retrieve_all called for packages: ${packages}"

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

	local filespec="$(get_component_filespec ${package})"
	# don't skip mingw_only components so we get md5sums and/or
        # git revisions
	if test "$(component_is_tar ${package})" = no; then
 	    local retrieve_ret=
	    retrieve ${package}
	    retrieve_ret=$?
	    if test ${retrieve_ret} -gt 0; then
		error "Failed retrieve of ${package}."
		return 1
	    fi
	else
	    fetch ${package}
	    if test $? -gt 0; then
		error "Couldn't retrieve tarball for ${package}"
		return 1
	    fi
	fi

    done

    notice "Retrieve all took ${SECONDS} seconds"

    return 0
}

# This gets the source tree from a remote host
# $1 - This should be a service:// qualified URL.  If you just
#       have a git identifier call get_URL first.
retrieve()
{
#    trace "$*"

    local component="$1"

    # None of the following should be able to fail with the code as it is
    # written today (and failures are therefore untestable) but propagate
    # errors anyway, in case that situation changes.
    local url=
    url="$(get_component_url ${component})" || return 1
    local repo=
    repo="$(get_component_filespec ${component})" || return 1
    local protocol="$(echo ${url} | cut -d ':' -f 1)"
    local repodir="${url}/${repo}"

    if ! validate_url "${repodir}"; then
	error "proper URL required"
	return 1
    fi

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
	dryrun "git clone ${git_reference_opt} -n --config 'remote.origin.fetch=+refs/changes/*:refs/remotes/changes/*' ${repodir} ${local_snapshots}/${repo}"
	if test $? -gt 0; then
	    error "Failed to clone master branch from ${url} to ${local_snapshots}/${repo}"
	    return 1
	fi
        retrieve_clone_update || return 1
    else
        if test x"${supdate}" = xyes; then
            retrieve_clone_update || return 1
        fi
    fi


    return 0
}

retrieve_clone_update()
{
    # update local clone with all refs, pruning stale branches
    dryrun "git -C ${local_snapshots}/${repo} remote update --prune > /dev/null"
    if test $? -gt 0; then
        error "Failed to update from ${url} to ${local_snapshots}/${repo}"
        return 1
    fi
}
