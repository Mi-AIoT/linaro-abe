#!/bin/bash
# 
#   Copyright (C) 2016 Linaro, Inc
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

# This file contains the logic which sequences the steps which are performed
# during a build

# build_steps is an associative array. The keys are the names of the enabled
# build steps
declare -A build_steps

# build_step_required indicates whether a step is required for the build to
# proceed further.
declare -A build_step_required

build_component_list=""
check_component_list=""

build_step_required[CHECKOUT]=1
build_step_CHECKOUT()
{
    checkout_all "$build_component_list"
}

build_step_required[MANIFEST]=1
build_step_MANIFEST()
{
    manifest="`manifest`"
}

build_step_required[BUILD]=1
build_step_BUILD()
{
    build_all "$build_component_list"
}

build_step_HELLO_WORLD()
{
    ## TODO: waiting for build() cleanup
    #hello_world
    true
}

build_step_CHECK()
{
    local check=""
    local build_names="$(echo $build_component_list | sed -e 's/stage[12]/gcc/')"
    for i in $check_component_list; do
        if is_package_in_runtests "${build_names}" "$i"; then
	    check="$check $i"
	fi
    done
    notice "Checking $check"
    check_all "$check"
}

build_step_TARSRC()
{
    do_tarsrc
}

build_step_TARBIN()
{
    do_tarbin
}

perform_build_steps()
{
    notice "enabled build steps (not in order): ${!build_steps[*]}"

    for i in CHECKOUT MANIFEST BUILD HELLO_WORLD CHECK TARSRC TARBIN; do
        if [ ! -z "${build_steps[$i]}" ]; then
	    # this step is enabled
            eval "build_step_$i"
	    if test $? -ne 0; then
		error "Step $i failed"
		return 1
	    fi
	else
	    # this step is not enabled, so we finish here if it's a
	    # required step.
	    if [ ! -z "${build_step_required[$i]}" ]; then
		break
	    fi
	fi
    done
}

# convert high-level command line operations into the list of steps which
# must be performed.
#
# set_build_steps <checkout|build|tarsrc|tarbin|check>
#
set_build_steps()
{
    case "$1" in
	checkout)
	    build_steps[CHECKOUT]=1
	    ;;
	build)
	    build_steps[CHECKOUT]=1
	    build_steps[MANIFEST]=1
	    build_steps[BUILD]=1
	    build_steps[HELLO_WORLD]=1
	    ;;
	tarsrc)
	    build_steps[TARSRC]=1
	    ;;
	tarbin)
	    build_steps[TARBIN]=1
	    ;;
	check)
	    build_steps[CHECK]=1
	    ;;
    esac
}

# set list of components to be checked out and built (if those steps are
# enabled in build_steps array)
set_build_component_list()
{
   build_component_list="$1"
}

get_build_component_list()
{
   echo "${build_component_list}"
}

# set list of components to be checked (make check) if CHECK build step is
# enabled in build_steps array)
set_check_component_list()
{
   check_component_list="$1"
}

get_check_component_list()
{
   echo "${check_component_list}"
}

