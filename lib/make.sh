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

# This performs all the steps to build a full cross toolchain
build_all()
{
#    trace "$*"
    
    local builds="$*"

    notice "build_all: Building components: ${builds}"

    local build_all_ret=

    # build each component
    for i in ${builds}; do
        local mingw_only="$(get_component_mingw_only $i)"
        if [ x"$mingw_only" = x"yes" ] && ! is_host_mingw ; then
            notice "Skipping component $i, which is only required for mingw hosts"
            continue
        fi
        local linuxhost_only="$(get_component_linuxhost_only $i)"
        if [ x"$linuxhost_only" = x"yes" ] && ! is_host_linux ; then
            notice "Skipping component $i, which is only required for Linux hosts"
            continue
        fi
        notice "Building all, current component $i"
        case $i in
            # Build stage 1 of GCC, which is a limited C compiler used to compile
            # the C library.
            libc)
                build ${clibrary}
                build_all_ret=$?
                ;;
            stage1)
                build gcc stage1
                build_all_ret=$?
                ;; 
            # Build stage 2 of GCC, which is the actual and fully functional compiler
            stage2)
		# FIXME: this is a seriously ugly hack required for building Canadian Crosses.
		# Basically the gcc/auto-host.h produced when configuring GCC stage2 has a
		# conflict as sys/types.h defines a typedef for caddr_t, and autoheader screws
		# up, and then tries to redefine caddr_t yet again. We modify the installed
		# types.h instead of the one in the source tree to be a tiny bit less ugly.
		# After libgcc is built with the modified file, it needs to be changed back.
		if is_host_mingw; then
		    sed -i -e 's/typedef __caddr_t caddr_t/\/\/ FIXME: typedef __caddr_t caddr_t/' ${sysroots}/libc/usr/include/sys/types.h
		fi

                build gcc stage2
                build_all_ret=$?
		# Reverse the ugly hack
		if is_host_mingw; then
		    sed -i -e 's/.*FIXME: //' ${sysroots}/libc/usr/include/sys/types.h
		fi
                ;;
            expat)
		# TODO: avoid hardcoding the version in the path here
		dryrun "rsync -av ${local_snapshots}/expat-2.1.0-1/include $prefix/usr/"
		if [ $? -ne 0 ]; then
		    error "rsync of expat include failed"
		    return 1
		fi
		dryrun "rsync -av ${local_snapshots}/expat-2.1.0-1/lib $prefix/usr/"
		if [ $? -ne 0 ]; then
		    error "rsync of expat lib failed"
		    return 1
		fi
		;;
            python)
		# The mingw package of python contains a script used by GDB to
		# configure itself, this is used to specify that path so we
		# don't have to modify the GDB configure script.
		# TODO: avoid hardcoding the version in the path here...
		export PYTHON_MINGW=${local_snapshots}/python-2.7.4-mingw32
		# The Python DLLS need to be in the bin dir where the
		# executables are.
		dryrun "rsync -av ${PYTHON_MINGW}/pylib ${PYTHON_MINGW}/dll ${PYTHON_MINGW}/libpython2.7.dll $prefix/bin/"
		if [ $? -ne 0 ]; then
		    error "rsync of python libs failed"
		    return 1
		fi
		;;
	    libiconv)
		# TODO: avoid hardcoding the version in the path here
		dryrun "rsync -av ${local_snapshots}/libiconv-1.14-3/include ${local_snapshots}/libiconv-1.14-3/lib $prefix/usr/"
		if [ $? -ne 0 ]; then
		    error "rsync of libiconv failed"
		    return 1
		fi
		;;
            *)
		build $i
                build_all_ret=$?
                ;;
        esac
        #if test $? -gt 0; then
        if test ${build_all_ret} -gt 0; then
            error "Failed building $i."
            return 1
        fi
    done

    # Notify that the build completed successfully
    build_success

    return 0
}

get_glibc_version()
{
    local src="`get_component_srcdir glibc`"
    local version=`grep VERSION $src/version.h | cut -d' ' -f3`
    if [ $? -ne 0 ]; then
	version="0.0"
    fi
    eval "echo $version"

    return 0
}

is_glibc_check_runable()
{
    local glibc_version=`get_glibc_version`
    local glibc_major=`echo $glibc_version | cut -d'.' -f1`
    local glibc_minor=`echo $glibc_version | cut -d'.' -f2`

    # Enable glibc make for non native build only for version 2.21
    # or higher. This is mostly because the check system on older glibc
    # do not work reliable with run-built-tests=no.
    if [[ ( $glibc_major -ge 3) ||
          (( $glibc_major -eq 2 && $glibc_minor -ge 21 )) ]]; then
      return 0
    fi

    return 1
}

check_all()
{
    local test_packages="${1}"

    # If we're building a full toolchain the binutils tests need to be built
    # with the stage 2 compiler, and therefore we shouldn't run unit-test
    # until the full toolchain is built.  Therefore we test all toolchain
    # packages after the full toolchain is built. 
    if test x"${test_packages}" != x; then
	notice "Testing components ${test_packages}..."
	if [ -n "${ABE_TARGET_BOARD_OPTIONS}" ]; then
	    notice "Using dejagnu target_board options: ${ABE_TARGET_BOARD_OPTIONS}"
	fi

	local check_ret=0
	local check_failed=

	is_package_in_runtests "${test_packages}" newlib
	if test $? -eq 0; then
	    make_check newlib
	    if test $? -ne 0; then
		check_ret=1
		check_failed="${check_failed} newlib"
	    fi
	fi

	is_package_in_runtests "${test_packages}" binutils
	if test $? -eq 0; then
	    make_check binutils
	    if test $? -ne 0; then
		check_ret=1
		check_failed="${check_failed} binutils"
	    fi
	fi

	is_package_in_runtests "${test_packages}" gcc
	if test $? -eq 0; then
	    make_check gcc stage2
	    if test $? -ne 0; then
		check_ret=1
		check_failed="${check_failed} gcc-stage2"
	    fi
	fi

	is_package_in_runtests "${test_packages}" gdb
	if test $? -eq 0; then
	    make_check gdb
	    if test $? -ne 0; then
		check_ret=1
		check_failed="${check_failed} gdb"
	    fi
	fi

	is_package_in_runtests "${test_packages}" glibc
	if test $? -eq 0; then
	    is_glibc_check_runable
	    if test $? -eq 0; then
		make_check glibc
		if test $? -ne 0; then
		    check_ret=1
		    check_failed="${check_failed} glibc"
		fi
	    fi
	fi

	is_package_in_runtests "${test_packages}" eglibc
	if test $? -eq 0; then
	    #make_check ${eglibc_version}
	    #if test $? -ne 0; then
		#check_ret=1
	        #check_failed="${check_failed} eglibc"
	    #fi
	    notice "make check on native eglibc is not yet implemented."
	fi

	if test ${check_ret} -ne 0; then
	    error "Failed checking of ${check_failed}."
	    return 1
	fi
    fi

    # Notify that the test run completed successfully
    test_success

    return 0
}


do_tarsrc()
{
    # TODO: put the error handling in, or remove the tarsrc feature.
    # this isn't as bad as it looks, because we will catch errors from
    # dryrun'd commands at the end of the build.
    notice "do_tarsrc has no error handling"
    if test "$(echo ${with_packages} | grep -c toolchain)" -gt 0; then
	release_binutils_src
	release_gcc_src
    fi
    if test "$(echo ${with_packages} | grep -c gdb)" -gt 0; then
        release_gdb_src
    fi
}

do_tarbin()
{
    # TODO: put the error handling in
    # this isn't as bad as it looks, because we will catch errors from
    # dryrun'd commands at the end of the build.
    notice "do_tarbin has no error handling"
    # Delete any previous release files
    # First delete the symbolic links first, so we don't delete the
    # actual files
    dryrun "rm -fr ${local_builds}/linaro.*/*-tmp ${local_builds}/linaro.*/runtime*"
    dryrun "rm -f ${local_builds}/linaro.*/*"
    # delete temp files from making the release
    dryrun "rm -fr ${local_builds}/linaro.*"

    if test x"${clibrary}" != x"newlib"; then
	binary_runtime
    fi

    binary_toolchain
    binary_sysroot

#    if test "$(echo ${with_packages} | grep -c gdb)" -gt 0; then
#	binary_gdb
#    fi
    notice "Packaging took ${SECONDS} seconds"
    
    return 0
}

build()
{
#    trace "$*"

    local component=$1
 
    local url="$(get_component_url ${component})"
    local srcdir="$(get_component_srcdir ${component})"
    local builddir="$(get_component_builddir ${component} $2)"

    if [ x"${srcdir}" = x"" ]; then
	# Somehow this component hasn't been set up correctly.
	error "Component '${component}' has no srcdir defined."
        return 1
    fi

    local version="$(basename ${srcdir})"
    local stamp=
    stamp="$(get_stamp_name $component build ${version} ${2:+$2})"

    # The stamp is in the build dir's parent directory.
    local stampdir="$(dirname ${builddir})"

    notice "Building ${component} ${2:+$2}"

    # We don't need to build if the srcdir has not changed!  We check the
    # build stamp against the timestamp of the srcdir.
    local ret=
    check_stamp "${stampdir}" ${stamp} ${srcdir} build ${force_build}
    ret=$?
    if test $ret -eq 0; then
	return 0
    elif test $ret -eq 255; then
        # Don't proceed if the srcdir isn't present.  What's the point?
        error "no source dir for the stamp!"
        return 1
    fi

    if [ x"$building" = x"no" ]; then
	return 0
    fi

    # configure_build is allowed to alter environment, e.g., set $PATH,
    # for build of a particular component, so run configure and build
    # in a sub-shell.
    (
	notice "Configuring ${component} ${2:+$2}"
	configure_build ${component} ${2:+$2}
	if test $? -gt 0; then
            error "Configure of $1 failed!"
            return $?
	fi
	# For debug purpose, print modification dates after configure
	notice "Source dir stamp after configure: ${srcdir} $(dryrun "stat -c %Y ${srcdir}") ${srcdir}/ $(dryrun "stat -c %Y ${srcdir}/")"
	
	# Clean the build directories when forced
	if test x"${force_build}" = xyes; then
            make_clean ${component} ${2:+$2}
            if test $? -gt 0; then
		return 1
            fi
	fi

	# Finally compile and install the libaries
	make_all ${component} ${2:+$2}
	if test $? -gt 0; then
            return 1
	fi
	
	# Build the documentation, unless it has been disabled at the command line.
	if test x"${make_docs}" = xyes; then
            make_docs ${component} ${2:+$2}
            if test $? -gt 0; then
		return 1
            fi
	else
            notice "Skipping make docs as requested (check host.conf)."
	fi
	
	# Install, unless it has been disabled at the command line.
	if test x"${install}" = xyes; then
            make_install ${component} ${2:+$2}
            if test $? -gt 0; then
		return 1
            fi
	else
            notice "Skipping make install as requested (check host.conf)."
	fi
	
	create_stamp "${stampdir}" "${stamp}"
	# For debug purpose, print modification dates after configure
	notice "Source dir stamp after build: ${srcdir} $(dryrun "stat -c %Y ${srcdir}") ${srcdir}/ $(dryrun "stat -c %Y ${srcdir}/")"
	
	local tag="$(create_release_tag ${component})"
	notice "Done building ${tag}${2:+ $2}, took ${SECONDS} seconds"
	
	# For cross testing, we need to build a C library with our freshly built
	# compiler, so any tests that get executed on the target can be fully linked.
    ) &
    ret=0 && wait $! || ret=$?

    return $ret
}

make_all()
{
#    trace "$*"

    local component=$1

    # Linux isn't a build project, we only need the headers via the existing
    # Makefile, so there is nothing to compile.
    if test x"${component}" = x"linux"; then
        return 0
    fi

    local builddir="$(get_component_builddir ${component} $2)"
    notice "Making all in ${builddir}"

    local make_flags="$extra_makeflags"
    # ??? Why disable parallel build for glibc?
    if test x"${parallel}" = x"yes" -a "$(echo ${component} | grep -c glibc)" -eq 0; then
	make_flags="${make_flags} -j ${cpus}"
    fi

    # Enable an errata fix for aarch64 that effects the linker
    if test "$(echo ${component} | grep -c glibc)" -gt 0 -a $(echo ${target} | grep -c aarch64) -gt 0; then
	make_flags="${make_flags} LDFLAGS=\"-Wl,--fix-cortex-a53-843419\" "
    fi

    case "$target" in
	aarch64*-mingw32)
	    # FIXME: See comment about fix-cortex-a53-843419 in config/gcc.conf.
	    true
	    ;;
	aarch64*)
	    local ldflags_for_target="-Wl,-fix-cortex-a53-843419"
	    # As discussed in
	    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=66203
	    # aarch64*-none-elf toolchains using newlib need the
	    # --specs=rdimon.specs option otherwise link fails because
	    # _exit etc... cannot be resolved. See commit message for
	    # details.
	    case "$target" in
		aarch64*-elf)
		    ldflags_for_target="${ldflags_for_target} --specs=rdimon.specs"
		    ;;
	    esac
	    make_flags="${make_flags} LDFLAGS_FOR_TARGET=\"${ldflags_for_target}\" "
	    ;;
	arm*-eabi)
	    # The same applies to arm*-eabi, since we configure newlib
	    # with --disable-newlib-supplied-syscalls.
	    ldflags_for_target="${ldflags_for_target} --specs=rdimon.specs"
	    make_flags="${make_flags} LDFLAGS_FOR_TARGET=\"${ldflags_for_target}\" "
	    ;;
    esac

    # Use pipes instead of /tmp for temporary files.
    if test x"${override_cflags}" != x -a x"${component}" != x"eglibc"; then
	make_flags="${make_flags} CFLAGS_FOR_BUILD=\"-pipe -g -O2\" CFLAGS=\"${override_cflags}\" CXXFLAGS=\"${override_cflags}\" CXXFLAGS_FOR_BUILD=\"-pipe -g -O2\""
    else
	make_flags="${make_flags} CFLAGS_FOR_BUILD=\"-pipe -g -O2\" CXXFLAGS_FOR_BUILD=\"-pipe -g -O2\""
    fi

    if test x"${override_ldflags}" != x; then
        make_flags="${make_flags} LDFLAGS=\"${override_ldflags}\""
    fi

    # All tarballs are statically linked
    make_flags="${make_flags} LDFLAGS_FOR_BUILD=\"-static-libgcc\""

    # Some components require extra flags to make: we put them at the
    # end so that config files can override
    local default_makeflags="$(get_component_makeflags ${component})"

    if test x"${default_makeflags}" !=  x; then
        make_flags="${make_flags} ${default_makeflags}"
    fi

    if test x"${CONFIG_SHELL}" = x; then
        export CONFIG_SHELL=${bash_shell}
    fi

    local makeret=
    # GDB and Binutils share the same top level files, so we have to explicitly build
    # one or the other, or we get duplicates.
    local logfile="${builddir}/make-${component}${2:+-$2}.log"
    record_artifact "log_make_${component}${2:+-$2}" "${logfile}"
    dryrun "echo NOTE: Building in ${builddir} | tee ${logfile}"
    dryrun "make SHELL=${bash_shell} -w -C ${builddir} ${make_flags} 2>&1 | tee -a ${logfile}"
    local makeret=$?
    
#    local errors="$(dryrun \"egrep '[Ff]atal error:|configure: error:|Error' ${logfile}\")"
#    if test x"${errors}" != x -a ${makeret} -gt 0; then
#       if test "$(echo ${errors} | egrep -c "ignored")" -eq 0; then
#           error "Couldn't build ${tool}: ${errors}"
#           exit 1
#       fi
#    fi

    # Make sure the make.log file is in place before grepping or the -gt
    # statement is ill formed.  There is not make.log in a dryrun.
#    if test -e "${builddir}/make-${tool}.log"; then
#       if test $(grep -c "configure-target-libgcc.*ERROR" ${logfile}) -gt 0; then
#           error "libgcc wouldn't compile! Usually this means you don't have a sysroot installed!"
#       fi
#    fi
    if test ${makeret} -gt 0; then
        warning "Make had failures!"
        return 1
    fi

    return 0
}

# Print path to dynamic linker in sysroot
# $1 -- whether dynamic linker is expected to exist
find_dynamic_linker()
{
    local strict="$1"
    local dynamic_linker c_library_version
    local dynamic_linkers tmp_dynamic_linker

    # Programmatically determine the embedded glibc version number for
    # this version of the clibrary.
    if test -x "${sysroots}/libc/usr/bin/ldd"; then
	c_library_version="$(${sysroots}/libc/usr/bin/ldd --version | head -n 1 | sed -e "s/.* //")"
	dynamic_linker="$(find ${sysroots}/libc -type f -name ld-${c_library_version}.so)"
	if [ x"$dynamic_linker" = x"" ]; then
	    dynamic_linkers=$(grep "^RTLDLIST=" "$sysroots/libc/usr/bin/ldd" \
				  | sed -e "s/^RTLDLIST=//" -e 's/^"\(.*\)"$/\1/g')
	    for tmp_dynamic_linker in $dynamic_linkers; do
		tmp_dynamic_linker="$(find $sysroots/libc -name "$(basename $tmp_dynamic_linker)")"
		if [ -f "$tmp_dynamic_linker" ]; then
		    if [ "$dynamic_linker" != "" ]; then
			error "Found more than one dynamic linker: $dynamic_linker $tmp_dynamic_linker"
			return 1
		    fi
		    dynamic_linker="$tmp_dynamic_linker"
		fi
	    done
	fi
    fi
    if $strict && [ -z "$dynamic_linker" ]; then
        error "Couldn't find dynamic linker ld-${c_library_version}.so in ${sysroots}/libc"
        exit 1
    fi
    echo "$dynamic_linker"
}

make_install()
{
#    trace "$*"

    local component=$1

    # Do not use -j for 'make install' because several build systems
    # suffer from race conditions. For instance in GCC, several
    # multilibs can install header files in the same destination at
    # the same time, leading to conflicts at file creation time.
    if echo "$makeflags" | grep -q -e "-j"; then
	warning "Make install flags contain -j: this may fail because of a race condition!"
    fi

    if test x"${component}" = x"linux"; then
        local srcdir="$(get_component_srcdir ${component}) ${2:+$2}"
	local ARCH="${target%%-*}"
	case "$ARCH" in
	    aarch64*) ARCH=arm64 ;;
	    arm*) ARCH=arm ;;
	    i?86*) ARCH=i386 ;;
	    powerpc*) ARCH=powerpc ;;
	esac
        dryrun "make -C ${srcdir} headers_install ARCH=${ARCH} INSTALL_HDR_PATH=${sysroots}/libc/usr"
        if test $? != "0"; then
            error "Make headers_install failed!"
            return 1
        fi
        return 0
    fi

    local builddir="$(get_component_builddir ${component} $2)"
    notice "Making install in ${builddir}"
    local logfile="${builddir}/make-${component}${2:+-$2}.log"
    record_artifact "log_install_${component}${2:+-$2}" "${logfile}"
    dryrun "echo NOTE: Installing in ${builddir} | tee -a ${logfile}"

    local make_flags=""
    if test "$(echo ${component} | grep -c glibc)" -gt 0; then
	# ??? Why build glibc with static libgcc?  To avoid adding
	# ??? compiler libraries to LD_LIBRARY_PATH?
	make_flags="install_root=${sysroots}/libc ${make_flags} LDFLAGS=-static-libgcc"
    fi

    if test x"${override_ldflags}" != x; then
        make_flags="${make_flags} LDFLAGS=\"${override_ldflags}\""
    fi

    # Don't stop on CONFIG_SHELL if it's set in the environment.
    if test x"${CONFIG_SHELL}" = x; then
        export CONFIG_SHELL=${bash_shell}
    fi

    if [ x"${component}" = x"gdb" -o x"${component}" = x"gdbserver" ]; then
        dryrun "make install-${component} ${make_flags} -w -C ${builddir} 2>&1 | tee -a ${logfile}"
    else
	dryrun "make install ${make_flags} -w -C ${builddir} 2>&1 | tee -a ${logfile}"
    fi
    if test $? != "0"; then
        warning "Make install failed!"
        return 1
    fi

    # Decide whether now is a good time to copy GCC libraries into
    # sysroot.
    local copy_gcc_libs=false
    if is_host_mingw; then
	# For mingw builds we copy sysroot from a linux-hosted toolchain.
	:
    elif get_component_list | grep -q "stage1"; then
	if [ x"${component}" = x"gcc" -a x"$2" = x"stage2" ]; then
	    # This is a two-stage build, so copy GCC libraries to sysroot after
	    # install of gcc stage2.
	    copy_gcc_libs=true
	fi
    else
	if [ x"$component" = x"$clibrary" ]; then
	    # This is a single-stage build (most likely native), so copy gcc
	    # libraries after libc install.
	    copy_gcc_libs=true
	fi
    fi

    if $copy_gcc_libs; then
	dryrun "copy_gcc_libs_to_sysroot"
	if test $? != "0"; then
            error "Copy of gcc libs to sysroot failed!"
            return 1
	fi
    fi

    return 0
}

# Copy sysroot to test container and print out ABE_TEST_* settings to pass
# to dejagnu.
# $1 -- test container
# $2 -- action: "install" our sysroot or "restore" original sysroot.
print_make_opts_and_copy_sysroot ()
{
    (set -e
     local test_container="$1"
     local action="$2"

     local user machine port
     user="$(echo $test_container | cut -s -d@ -f 1)"
     machine="$(echo $test_container | sed -e "s/.*@//g" -e "s/:.*//g")"
     port="$(echo $test_container | cut -s -d: -f 2)"

     if [ x"$port" = x"" ]; then
	 error "Wrong format of test_container: $test_container"
	 return 1
     fi

     if [ x"$user" = x"" ]; then
	 user=$(ssh -p$port $machine whoami)
     fi

     # The overall plan is to:
     # 1. rsync libs to /tmp/<new-sysroot>
     # 2. regenerate /etc/ld.so.cache to include /tmp/<new-sysroot>
     #    as preferred place for any libs that it has.
     # 3. we need to be careful to update ld.so.cache at the same time
     #    as we update symlink for /lib/ld-linux-*so*; otherwise we risk
     #    de-synchronizing ld.so and libc.so, which will break the system.
     
     local ldso_bin lib_path ldso_link
     ldso_bin=$(find_dynamic_linker true)
     lib_path=$(dirname "$ldso_bin")

     local -a ldso_links
     ldso_links=($(find "$lib_path" -type f,l -name "ld-linux*.so*"))

     if [ "${#ldso_links[@]}" != "1" ]; then
	 error "Exactly one ld.so file or symlink is expected: ${ldso_links[@]}"
	 return 1
     fi
     ldso_link="${ldso_links[@]}"

     # Glibc 2.34 and newer provides only straight ld-linux-ARCH.so.N binaries
     # with no symlinks, so $ldso_bin and $ldso_link are now the same.
     # We could simplify below logic a bit, but, imo, it's slightly better
     # to keep support for ld.so symlinks.
     local dest_ldso_bin dest_lib_path dest_ldso_link
     dest_lib_path=$(ssh -p$port $user@$machine mktemp -d)
     dest_ldso_bin="$dest_lib_path/$(basename $ldso_bin)"
     dest_ldso_link="/$(basename "$lib_path")/$(basename "$ldso_link")"

     if [ "$action" = "restore" ]; then
	 ssh -p$port $user@$machine sudo /tmp/restore.sh
	 return 0
     fi

     # Rsync libs and ldconfig to the target
     if ! rsync -az --delete -e "ssh -p$port" "$lib_path/" "$lib_path/../sbin/" "$user@$machine:$dest_lib_path/"; then
	 error "Cannot rsync sysroot to $user@machine:$port:$dest_lib_path/"
	 return 1
     fi

     # Packages in recent Ubuntu distros (20.04 and 22.04) are built against
     # non-glibc libcrypt.so, and sudo, ssh, and other binaries fail
     # to authorize users during testing if glibc's libcrypt.so is positioned
     # first on the library search path.  The failure is silent, but manifests
     # itself in failure to find XCRYPT_* versions in output
     # "LD_DEBUG=libs sudo ls".
     # Disabling libcrypt in our glibc build (--disable-crypt) causes
     # GCC's sanitizers to fail to build.  So, rather than disabling libcrypt
     # during build, we remove it from target sysroot
     local libcrypt_workaround=false
     if ssh -p$port $user@$machine dpkg -L libcrypt1 \
	     | grep '^/lib.*/libcrypt.so.1$' >/dev/null; then
	 libcrypt_workaround=true
     fi

     # Generate install script to install our sysroot.
     # The most tricky moment!  We need to replace ld.so and re-generate
     # /etc/ld.so.cache in a single command.  Otherwise ld.so and libc will
     # get de-synchronized, which will render container unoperational.
     #
     # Adding new, rather than replacing, ld.so link is rather mundane.
     # E.g., adding ld.so for new abi (ILP32) is extremely unlikely to break
     # LP64 system.
     #
     # We use Ubuntu containers for testing, and ubuntu rootfs has /lib/ld.so
     # as a symlink to /lib/<target/ld.so.  Therefore, we override the symlink
     # to install our ld.so.
     # shellcheck disable=SC2087
     ssh -p$port $user@$machine tee /tmp/install.sh > /dev/null <<EOF
#!/bin/bash

set -euf -o pipefail

dest_ldsoconf=\$(mktemp)

if $libcrypt_workaround; then
  rm -f $dest_lib_path/libcrypt.so.1
fi

echo $dest_lib_path >> \$dest_ldsoconf
cat /etc/ld.so.conf >> \$dest_ldsoconf
ln -f -s $dest_ldso_bin $dest_ldso_link \\
  && $dest_lib_path/ldconfig -f \$dest_ldsoconf
EOF

     # Generate restore script to restore original glibc setup.
     # Once ld.so symlink is replaced we can no longer run new non-static
     # executables -- sudo, bash, etc..  Therefore, we need to run ldconfig
     # in the same "sudo bash -c" command.  Also, on Ubuntu distro ldconfig
     # is a shell script, which call ldconfig.real -- try running that directly,
     # since we will not be able to start bash.
     local orig_ldso_link
     orig_ldso_link=$(ssh -p$port $user@$machine readlink "$dest_ldso_link")
     # shellcheck disable=SC2087
     ssh -p$port $user@$machine tee /tmp/restore.sh > /dev/null <<EOF
#!/bin/bash

set -euf -o pipefail

ln -f -s $orig_ldso_link $dest_ldso_link \\
  && ldconfig.real || ldconfig
EOF

     ssh -p$port $user@$machine chmod +x /tmp/install.sh /tmp/restore.sh

     if ! ssh -p$port $user@$machine sudo /tmp/install.sh; then
	 error "Could not install new sysroot"
	 return 1
     fi

     # Profiling tests attempt to create files on the target with the same
     # paths as on the host.  When local and remote users do not match, we
     # get "permission denied" on accessing /home/$USER/.  Workaround by
     # creating $(pwd) on the target that target user can write to.
     if [ x"$user" != x"$USER" ]; then
	 ssh -p$port $user@$machine sudo bash -c "\"mkdir -p $(pwd) && chown $user $(pwd)\""
     fi

     echo "ABE_TEST_CONTAINER_USER=$user ABE_TEST_CONTAINER_MACHINE=$machine SCHROOT_PORT=$port"
    )
}

# $1 - The component to test
# $2 - The expfile specification. Can be: myfile.exp,
#      path/to/myfile.exp or tool:path/to/myfile.exp
#
# The rules are as follows:
#
# - if $flag is of the form $tool:$exp, include $flag in the list if
#   $component and $tool match. For the binutils component, binutils,
#   gas and ld are acceptable tools. For the gdb component, gdb is the
#   only relevant tool.
#
#   For gcc, include $flag if the $tool prefix is one of gcc, g++,
#   gfortran, lib*, obj*. This is because the gcc testsuite does not
#   accept $exp names with path separators. This way, we also skip
#   $flag if it is prefixed by a $tool that does not correspond to
#   $component
#
#   In other cases, report $tool as "none", so as to skip collecting
#   testname for this component/tool
#
# - if $flag has no $tool prefix, but contains a "/", ignore it for
#   gcc, accept it otherwise
#
# - if there is no $tool prefix, report $tool as "any", so that
#   testcases are taken into account for this component/tool
#
# For instance, if $component is gdb, we accept all of break.exp,
# gdb.base/break.exp, gdb:gdb.base/break.exp (note that supplying all
# these flags together is later rejected as ambiguous).
#
# if $component is gcc, we accept compile.exp,
# gcc:gcc.c-torture/execute/execute.exp, but not
# gcc.c-torture/execute/execute.exp (which would cause errors when
# executing "make check" for g++ or gfortran).
exp_to_tool()
{
    local component="$1"
    local exp="$2"
    local tool=""

    case "$exp" in
	*:*)
	    tool=${exp%:*}
	    case "$component:$tool" in
		binutils:binutils|\
		    binutils:gas|\
		    binutils:ld|\
		    gcc:gcc|\
		    gcc:g++|\
		    gcc:gfortran|\
		    gcc:go|\
		    gcc:gotools|\
		    gcc:lib*|\
		    gcc:obj*|\
		    gdb:gdb|\
		    newlib:newlib|\
		    glibc:glibc)
		;;
		*:*)
		    # If $tool does not belong to $component, ignore it
		    tool="none"
		    ;;
	    esac
	    ;;
	*/*)
	    case $component in
		# Ignore runtestflags with dir name for GCC and no
		# tool prefix
		gcc)
		    warning "Skipping runtestflag $flag for $component as it does not support path components unless prefixed with the appropriate tool name"
		    tool="none"
		    ;;
		*)
		    tool="any"
		    ;;
	    esac
	    ;;
	*)
	    # No $tool prefix, so $exp can match any tool/component
	    tool="any"
	    ;;
    esac

    echo "$tool"
}

# $1 - The component to test
# $2 - The tool to test, as reported by exp_to_tool
#
# Given a component/tool pair, return the buildir subdirectory into
# which we should execute the testsuite. Return "none" if no test
# should be run.
#
# For GCC we need a special handling of the user-supplied
# runtestflags.  Indeed, GCC makes use of runtest's --tool option to
# find some of the Expect library functions.
tool_to_dirs()
{
    local component="$1"
    local tool="$2"
    local dirs="none"

    case "$component" in
	binutils)
	    case "$tool" in
		binutils|gas|ld)
		    dirs="/$tool"
		    ;;
		any)
		    dirs="/binutils /gas /ld"
		    ;;
	    esac
	    ;;
	gcc)
	    dirs="/"
	    ;;
	gdb|glibc)
	    case "$tool" in
		none) ;;
		*)
		    dirs="/"
		    ;;
	    esac
	    ;;
	newlib)
	    # We need a special case for newlib, to bypass its
	    # multi-do Makefile targets that do not properly
	    # propagate multilib flags. This means that we call
	    # runtest only once for newlib.
	    case "$tool" in
		*)
		    dirs="/${target}/newlib"
		    ;;
	    esac
	    ;;
    esac

    echo "$dirs"
}

# $1 - The component to test
# $2 - The tool to test, as reported by exp_to_tool
#
# Given a component/tool pair, return the "check" target to use when
# invoking make.
#
# For GCC we need a special handling of the user-supplied
# runtestflags.  Indeed, GCC makes use of runtest's --tool
# option to find some of the Expect library functions.
tool_to_check()
{
    local component="$1"
    local tool="$2"
    local check="check"

    case $component in
	gcc)
	    case $tool in
		any) ;;
		libstdc++) check="check-target-libstdc++-v3" ;;
		lib*) check="check-target-$tool" ;;
		gotools) check="check-gotools" ;;
		gcc) check="check-gcc-c" ;;
		g++) check="check-gcc-c++" ;;
		gfortran) check="check-gcc-fortran" ;;
		*) check="check-gcc-$tool" ;;
	    esac
	    ;;
	gdb)
	    check="check-gdb"
	    ;;
	glibc)
	    check="check"
	    ;;
    esac

    echo "$check"
}

# Create tests.log from output of failed glibc tests.
create_glibc_tests_log ()
{
    (
    set -euf -o pipefail
    local builddir="$1"

    if ! [ -f "$builddir/tests.sum" ]; then
	return 0
    fi

    local test_log="$builddir/tests.log"
    echo "=== glibc failures ===" > "$test_log"

    local test_result
    while IFS= read -r -d '' test_result; do
	if grep -q -E "^(PASS|XFAIL):" "$test_result"; then
	    continue
	fi

	echo >> "$test_log"
	cat "$test_result" >> "$test_log"

	# Add output of failed test
	test_result="${test_result%.test-result}.out"
	if [ -f "$test_result" ]; then
	    cat "$test_result" >> "$test_log"
	fi
    done < <(find "$builddir" -name "*.test-result" -print0)
    )
}

# $1 - The component to test
# $2 - If set to anything, installed tools are used'
make_check()
{
#    trace "$*"

    local component=$1
    local builddir="$(get_component_builddir ${component} $2)"

    if [ x"${builddir}" = x"" ]; then
	# Somehow this component hasn't been set up correctly.
	error "Component '${component}' has no builddir defined."
        return 1
    fi

    # Some tests cause problems, so don't run them all unless
    # --enable alltests is specified at runtime.
    local ignore="dejagnu gmp mpc mpfr make eglibc linux gdbserver"
    for i in ${ignore}; do
        if test x"${component}" = x$i -a x"${alltests}" != xyes; then
            return 0
        fi
    done
    notice "Making check in ${builddir}"

    # We do not want to add $prefix/bin to PATH unconditionally during
    # build (see commit 70da86d2b5a46cde72063b420086a68837ce5b89 for
    # more context), but some testsuites (e.g. GCC) make use of
    # $target-objdump and friends during testing. Make sure Dejagnu
    # can find them.
    # Like we do in build(), use a sub-shell.
    (
    export PATH="$local_builds/destdir/$build/bin:$PATH"
    notice "Setting for $component${2:+ $2} check PATH=$PATH"

    local make_flags=""
    # Use pipes instead of /tmp for temporary files.
    if test x"${override_cflags}" != x -a x"$2" != x"stage2"; then
        make_flags="${make_flags} CFLAGS_FOR_BUILD=\"${override_cflags}\" CXXFLAGS_FOR_BUILD=\"${override_cflags}\""
    else
        make_flags="${make_flags} CFLAGS_FOR_BUILD=\"-pipe\" CXXFLAGS_FOR_BUILD=\"-pipe\""
    fi

    if test x"${override_ldflags}" != x; then
        make_flags="${make_flags} LDFLAGS_FOR_BUILD=\"${override_ldflags}\""
    fi

    local -a runtestflags

    # ??? No idea about the difference (if any?) between $runtest_flags
    # ??? and $component_runtestflags.  Both seem to be empty all the time.
    if [ x"$runtest_flags" != x"" ]; then
        runtestflags+=("$runtest_flags")
    fi
    local component_runtestflags
    component_runtestflags=$(get_component_runtestflags $component)
    if [ x"$component_runtestflags" != x"" ]; then
	runtestflags+=("$component_runtestflags")
    fi
    if [ ${#extra_runtestflags[@]} -ne 0 ]; then
	runtestflags+=("${extra_runtestflags[@]}")
    fi

    if test x"${parallel}" = x"yes"; then
	case "${target}" in
	    "$build"|*"-elf"*|armeb*) make_flags="${make_flags} -j ${cpus}" ;;
	    # Double parallelization when running tests on remote boards
	    # to avoid host idling when waiting for the board.
	    *) make_flags="${make_flags} -j $((2*${cpus}))" ;;
	esac
    fi

    # load the config file for Linaro build farms
    export DEJAGNU=${topdir}/config/linaro.exp

    # Run tests
    local checklog="${builddir}/check-${component}.log"
    record_artifact "log_check_${component}" "${checklog}"

    local exec_tests
    exec_tests=false

    case "$component" in
	binutils)
	    exec_tests=true
	    ;;
	gcc)
	    exec_tests=true

	    if [ x"$send_results_to" != x ]; then
		# LAST_UPDATED is used when sending results summaries.
		# This file is not committed in the GCC repo, but is
		# used by contrib/test_summary if present in $srcdir.
		#
		# We generate almost the same contents as in
		# gcc/REVISION (see configure_build() in
		# lib/configure.sh), but we add $target and
		# $ABE_TARGET_BOARD_OPTIONS so that this information
		# is more obvious when reading the email report.
		#
		# The reason we do this in two places is because in
		# configure_build() we don;t know
		# $ABE_TARGET_BOARD_OPTIONS, for instance if the user
		# invokes ABE twice, once to build the toolchain
		# (without $ABE_TARGET_BOARD_OPTIONS), and once to run
		# the tests (with $ABE_TARGET_BOARD_OPTIONS, skipping
		# the build part, so too late for an update to
		# gcc/VERSION to be taken into account).  (This is
		# what we do in CI)
		#
		# If we accept not to provide
		# $ABE_TARGET_BOARD_OPTIONS in the summaries, we could
		# merge the creation of LAST_UPDATED with that of
		# gcc/REVISION in configure_build().
		local revstring="$(get_component_revision ${component})"
		local branch="$(get_component_branch ${component})"
		local srcdir="$(get_component_srcdir ${component})"

		# Try to generate a nicer revision
		if [ -d ${srcdir}/.git ]; then
		    revstring=$(git -C ${srcdir} describe --match "basepoints/*" \
				    --match "releases/*" ${revstring}  | sed 's,^basepoints/,,')
		fi

		local long_config="$target $ABE_TARGET_BOARD_OPTIONS"
		dryrun "echo $(date --utc --iso-8601=seconds) '(${branch} revision' $revstring')' $long_config | tee ${srcdir}/LAST_UPDATED"
	    fi

	    ;;
	gdb)
	    exec_tests=true
	    ;;
	glibc)
	    # The glibc tests are built in two different modes (enabled at
	    # configure time):
	    #
	    # 1. No RPATH defined, tests will run by issuing the loader along
	    #    with the required library paths.  It is the default option.
	    # 2. RPATH defined, tests will have RPATH pointing to the build
	    #    directory, so the kernel will be responsible for running the
	    #    loader.  It enables with --enable-hardcoded-path-in-tests.
	    #
	    # In both cases, the loader consults the system cache
	    # (ld.so.cache), so any compiler dynamic library (libgcc_s.so for
	    # instance) is supplied by the system.
	    #
	    # However, this might fail for container tests, where even
	    # test-container (the binary that setups and runs the tests in a
	    # container mode) creates a loader cache that might not contain
	    # the required libraries.  The glibc build system tries to check
	    # and provide the required libraries by tracing the DT_NEEDED ones
	    # from a test binary, but the tracing inhibits the system loader,
	    # and thus it will not copy the required system libraries.  It is
	    # expected the user to copy the required libraries to build a
	    # directory.
	    #
	    # This works for case 2., however, test-container does not issue
	    # the loader for case 1.: it will parse the command arguments,
	    # execute the binary and the kernel will be responsible for
	    # starting the loader.  This has the side-effect of ignoring all
	    # the defined --library-path and thus making the compiler
	    # libraries copy trick ineffective.
	    #
	    # So we copy the compiler libraries on both the build directory
	    # and on the sysroot used by the test-container to set each test.
	    # The latter will place the libraries on the default system path,
	    # which will be included in the loader cache as well.

	    dryrun "copy_gcc_libc_to_builddir ${builddir}"
	    if [ $? -ne 0 ]; then
	       error "Copy of gcc libs to build directory failed!"
	       return 1
	    fi



	    local exec_prefix=$(grep -w "prefix.*=" ${builddir}/config.make | cut -d'=' -f2)
	    local build_libdir=$(grep -w libdir ${builddir}/config.make | cut -d'=' -f2)
	    # eval is required because libdir is in the form '${exec_prefix}/<lib>',
	    # so it expands ${exec_prefix}.
	    local build_libdir_expanded=$(echo $(eval echo ${build_libdir}))

	    local testroot_libdir="${builddir}/testroot.pristine/${build_libdir_expanded}"
	    dryrun "mkdir -p ${testroot_libdir}"
	    dryrun "copy_gcc_libc_to_builddir ${testroot_libdir}"
	    if [ $? -ne 0 ]; then
	      error "Copy of gcc libs to testroot directory failed!"
	      return 1
	    fi
	    ;;
	newlib)
	    ;;
    esac

    local ldso_bin test_flags

    ldso_bin=$(find_dynamic_linker false)
    if [ x"$ldso_bin" != x"" ]; then
	# If we have ld.so, then we should have a sysroot for testing.
	# If we don't have ld.so, then we are testing native GCC against
	# system libraries.
	test_flags="$test_flags --sysroot=$sysroots/libc"
    fi

    local schroot_make_opts
    if $exec_tests && [ x"$test_container" != x"" ]; then
	schroot_make_opts=$(print_make_opts_and_copy_sysroot "$test_container" \
							     "install")
	if [ $? -ne 0 ]; then
	    error "Cannot initialize sysroot on $test_container"
	    return 1
	fi
    elif [ x"${build}" = x"${target}" ]; then
	schroot_make_opts="ABE_TEST_CONTAINER=local"
	if [ x"$ldso_bin" != x"" ]; then
	    local lib_path
	    lib_path=$(dirname "$ldso_bin")
	    # For testing on the local machine we need to link tests against
	    # ldso and libraries in $sysroots/libc
	    test_flags="$test_flags -Wl,-dynamic-linker=$ldso_bin"
	    test_flags="$test_flags -Wl,-rpath=$lib_path"
	fi
    fi

    if [ x"$ldso_bin" != x"" ] && $exec_tests; then
        touch ${sysroots}/libc/etc/ld.so.cache
        chmod 700 ${sysroots}/libc/etc/ld.so.cache
    fi

    # Remove existing logs so that rerunning make check results
    # in a clean log.
    if test -e ${checklog}; then
	# This might or might not be called, depending on whether make_clean
	# is called before make_check.  None-the-less it's better to be safe.
	notice "Removing existing check-${component}.log: ${checklog}"
	rm ${checklog}
    fi

    notice "Redirecting output from the testsuite to $checklog"

    case "$component:$check_buffer_workaround" in
	gcc:gcc-read1)
	    dryrun "make read1 -w -C ${abe_top}"
	    make_flags="${make_flags} EXPECT=${abe_top}/expect-read1"
	    ;;
	gdb:gdb-read1)
	    local read1_dir=""
	    [ "$component" = "gdb" ] && read1_dir="/gdb/testsuite"
	    dryrun "make read1 -w -C ${builddir}${read1_dir} >> $checklog 2>&1"
	    if [ $? != 0 ]; then
		error "make read1 -w -C ${builddir}${read1_dir} failed."
		return 1
	    fi
	    make_flags="${make_flags} READ1=1"
	    ;;
	gcc:expect-stdbuf-0)
	    make_flags="${make_flags} EXPECT=${topdir}/scripts/expect-stdbuf-0"
	    ;;
	gcc:expect-stdbuf-1)
	    make_flags="${make_flags} EXPECT=${topdir}/scripts/expect-stdbuf-1"
	    ;;
	gcc:expect-stdbuf-L)
	    make_flags="${make_flags} EXPECT=${topdir}/scripts/expect-stdbuf-L"
	    ;;
    esac

    local testsuite_mgmt="$gcc_compare_results/contrib/testsuite-management"
    local validate_failures="$testsuite_mgmt/validate_failures.py"

    # Prepare temporary fail files
    local new_fails new_passes baseline_flaky new_flaky
    local new_fails_for_deciding new_passes_for_deciding
    local known_flaky_and_fails_for_deciding flaky_and_fails_for_output
    new_fails=$(mktemp)
    new_fails_for_deciding=$(mktemp)
    new_passes=$(mktemp)
    new_passes_for_deciding=$(mktemp)
    baseline_flaky=$(mktemp)
    known_flaky_and_fails_for_deciding=$(mktemp)
    flaky_and_fails_for_output=$(mktemp)

    if [ "$flaky_failures" = "" ]; then
	new_flaky=$(mktemp)
    else
	notice "Using flaky fails file $flaky_failures"
	cp "$flaky_failures" "$baseline_flaky"
	true > "$flaky_failures"
	new_flaky="$flaky_failures"
    fi

    local prev_try_fails new_try_fails dir_fails
    prev_try_fails=$(mktemp)
    new_try_fails=$(mktemp)
    dir_fails=$(mktemp)

    if [ "$expected_failures" != "" ]; then
	notice "Using expected fails file $expected_failures"
	cp "$expected_failures" "$prev_try_fails"
    fi

    local -a expiry_date_opt=()
    if [ "$failures_expiration_date" != "" ]; then
	expiry_date_opt+=(--expiry_date "$failures_expiration_date")
    fi

    # Construct the initial $known_flaky_and_fails_for_deciding and
    # $flaky_and_fails_for_output lists.
    #
    # For the first iteration (try #0) we expect fails, passes and flaky tests
    # to be the same as in provided $expected_failures and $flaky_failures.
    # We will exit after running the testsuites for a single try if we
    # do not see any difference in test results compared to the provided
    # baseline.
    #
    # However, if we do see a difference in results after the first try, then
    # we will iterate testing until we see no difference between $try-1 and
    # $try results.  Each difference between $try-1 and $try will be recorded
    # in $new_flaky list, so with every try we will ignore more and more
    # tests as flaky.  We collect failures of the current try in $new_try_fails,
    # which then becomes $prev_try_fails on $try+1.  When generating the
    # difference that will go into $new_flaky we don't compare against the
    # provided $baseline_flaky, so that any detected flaky failure will appear
    # in $new_flaky even if it's already in the baseline flaky list.  This is
    # why $flaky_and_fails_for_output doesn't include the baseline flaky results
    # and is done so that the list of flaky tests produced at the end of
    # make_check has some redundancy with it.
    #
    # Note that we generate $prev_try_fails and $new_try_fails without regard
    # for flaky tests.  Therefore, $validate_failures that generate $new_fails
    # and $new_passes will see same tests with and without flaky attributes.
    # Validate_failure uses python sets to store results, so the first entry
    # wins.  Therefore, we need to put lists of flaky tests before lists of
    # expected fails -- $prev_try_fails.
    #
    # This approach is designed to shake out both PASS->FAIL and FAIL->PASS
    # tests equally well.  It is motivated by libstdc++ test
    # FAIL: 29_atomics/atomic/compare_exchange_padding.cc execution test
    # which almost always fails on armhf, but passes once in a blue moon.
    #
    # The previous approach handled flaky tests that PASS or FAIL with
    # comparable frequencies or the tests that mostly PASS, but sometimes
    # FAIL.  It could not, however, handle flaky tests that mostly FAIL,
    # but sometimes PASS.
    #
    # With the previous approach, when the test passed on the first try,
    # we didn't trigger additional iterations, and didn't have a chance
    # to mark the test as flaky.  Therefore this build would see a progression
    # on this test, and the next build would detect this test as a regression.
    # It would try to bisect it, which would not detect a regression
    # (because the test almost always fails), and the bisect would trigger
    # a refresh-baseline build, which would re-add the test into expected
    # failures.  Then things will be quiet for a while until the test passes
    # again.  The only chance for us to mark the test as flaky with
    # the previous approach would be to get very lucky and have the test
    # pass (which is very rare) while having another test fail in the same
    # libstdc++:libstdc++-dg/conformance.exp testsuite.
    #
    # With the new approach when this test [rarely] passes, we will detect
    # that in comparison with "$known_flaky_and_fails_for_deciding", and, if
    # $try==0, trigger another iteration of testing to confirm stability of
    # the new PASS.  The test will fail on the next iteration, and we will add
    # it to $new_flaky list.  If the test passes during $try!=0, we will add
    # it to the $new_flaky list immediately.

    cat > "$known_flaky_and_fails_for_deciding" <<EOF
@include $new_flaky
@include $baseline_flaky
@include $prev_try_fails
EOF

    # This file doesn't contain $baseline_flaky and is used to find the new
    # flaky tests to be added to $new_flaky in each try.
    cat > "$flaky_and_fails_for_output" <<EOF
@include $new_flaky
@include $prev_try_fails
EOF

    # Example iterations with binutils component:
    # try#0 runtestflags=""  -> tools=(any) dirs=(/binutils /gas /ld)
    #   detect failures in both gas and ld
    # try#1 runtestflags="gas:gas.exp ld:ld.exp" -> tools=(gas ld)  dirs=(/gas /ld)
    #   we need different lists of xfails/flaky tests for each tool/dir,
    #   otherwise we'll think that ld has gas' failures as flaky ld tests.

    local -a failed_exps=(${runtestflags[@]})
    local try=0
    local more_tests_to_try=true

    # The key in sums is the original name of the sum file, and the value is a list of
    # the sum files produced by all the testsuite runs, separated by ';' (because bash
    # doesn't support arrays within arrays).
    local -A sums=()

    while $more_tests_to_try; do

	more_tests_to_try=false

	# Compute which user-supplied runtestflags are relevant to this
	# component, and the corresponding directories and "make check"
	# targets.
	local -A tool2dirs=()
	local -A tool2exps=()
	local -A tool2check=()
	local flag

	for flag in "${failed_exps[@]}"
	do
	    local flag_tool=$(exp_to_tool "$component" "$flag")
	    local this_runtestflag=${flag#*:}
	    # If flag_tool is not relevant to the current component, do
	    # not include it in the list.
	    if [ "$flag_tool" = "none" ]; then
		continue
	    fi

	    tool2dirs["$flag_tool"]=$(tool_to_dirs "$component" "$flag_tool")
	    tool2exps["$flag_tool"]="${tool2exps["$flag_tool"]} $this_runtestflag"
	    tool2check["$flag_tool"]=$(tool_to_check "$component" "$flag_tool")
	done
	failed_exps=()

	# If the user supplied both non-prefixed and prefixed runtestflags
	# that would apply to this component/tool, skip the non-prefixed
	# ones.

	# For instance with execute.exp g++:compile.exp, we would have to
	# run the g++ tests twice:
	# - from toplevel, using 'make check'
	# - from /gcc, using 'make check-g++'
	# and the second call would overwrite g++.sum
	if [ ${#tool2dirs[@]} -gt 1 ] && [ "${tool2dirs[any]}" != "" ]; then
	    warning "Ignoring ambiguous runtestflags for $component: ${tool2exps[any]}"
	    warning "Prefix these runtestflags with $component: if relevant"
	    unset tool2dirs[any]
	    unset tool2exps[any]
	    unset tool2check[any]
	fi

	# If no runtestflag was supplied or none applies to this
	# component, use the defaults
	if [ ${#tool2dirs[@]} -eq 0 ]; then
	    flag_tool="any"
	    tool2dirs["$flag_tool"]=$(tool_to_dirs "$component" "$flag_tool")
	    tool2check["$flag_tool"]=$(tool_to_check "$component" "$flag_tool")
	fi

	# Increase timeout with each consecutive try.  This allows us
	# to start with [short] default timeout and then re-run only
	# the failed tests with increased timeout.  This will add tests
	# with inadequate timeout settings to the flaky list.
	#
	# In particular, glibc has short timeout for tests, and some tests
	# consistently require more time, e.g., nptl/ and malloc/ tests.
	# For now, only glibc tests support $TIMEOUTFACTOR, and we will add
	# it to DejaGnu board files later, if required.
	#
	# Note that we are running in a sub-shell (see "export PATH=" above),
	# so this setting is "local".
	export TIMEOUTFACTOR=$(($try + 1))

	local result=0
	local tool

	for tool in "${!tool2dirs[@]}"; do
	    local dirs="${tool2dirs[$tool]}"
	    local dir

	    for dir in $dirs; do
		local check_targets="${tool2check[$tool]}"

		local make_runtestflags=""
		if [ -n "${tool2exps[$tool]}" ]; then
		    if [ "$component" != "glibc" ]; then
			make_runtestflags="RUNTESTFLAGS=\"${tool2exps[$tool]}\""
		    else
			make_runtestflags="subdirs=\"${tool2exps[$tool]}\""
		    fi
		fi

		# This loop is executed only once, we keep the loop
		# structure to make early exits easier.
		while true; do
		    notice "Starting testsuite run #$try."

		    if [ "$component" = "glibc" ]; then
			notice "Preparing glibc for testing"
			dryrun "make tests-clean ${make_flags} ${make_runtestflags} -w -i -k -C ${builddir}$dir >> $checklog 2>&1"
			# Glibc's tests-clean misses several tests,
			# in particular, derivative malloc tests like
			# *-hugetbl*, *-mcheck, etc.
			# Remove artifacts of these ourselves so that we can
			# detect them as flaky.
			find "${builddir}$dir" -name "*.out" -delete
			find "${builddir}$dir" -name "*.test-result" -delete
		    fi

		    # Testsuites (I'm looking at you, GDB), can leave stray processes
		    # that inherit stdout of below "make check".  Therefore, if we pipe
		    # stdout to "tee", then "tee" will wait on output from these
		    # processes for forever and ever.  We workaround this by redirecting
		    # output to a file that can be "tail -f"'ed, if desired.
		    # A proper fix would be to fix dejagnu to not pass parent stdout
		    # to testcase processes.
		    dryrun "make ${check_targets} FLAGS_UNDER_TEST=\"$test_flags\" PREFIX_UNDER_TEST=\"$prefix/bin/${target}-\" QEMU_CPU_UNDER_TEST=${qemu_cpu} ${schroot_make_opts} ${make_flags} ${make_runtestflags} -w -i -k -C ${builddir}$dir >> $checklog 2>&1"
		    if [ $? != 0 ]; then
			# Make is told to ignore errors, so it's really not supposed to fail.
			warning "make ${check_targets} -C ${builddir}$dir failed."
			result=1
			break
		    fi

		    # Remove glibc's subdir-tests.sum and gdb's test .sum
		    # files to avoid confusing validate_failures.py
		    case "$component" in
			glibc)
			    find "${builddir}$dir" -name subdir-tests.sum \
				 -delete
			    create_glibc_tests_log "${builddir}$dir"
			    ;;
			gdb)
			    find "${builddir}$dir" \
				 -path '*/gdb/testsuite/outputs/*.sum' -delete
			    ;;
		    esac

		    if ! $rerun_failed_tests; then
			# No need to try again.
			break
		    fi

		    local -a failed_exps_for_dir=()

		    # We do two sets of validate_failures.py runs:
		    #
		    # In the first one we compare with the previous try's
		    # failures plus all known flaky tests.  We use the exit
		    # status to decide whether to do another try of the
		    # testsuite.
		    #
		    # In the second one we compare with the previous try's
		    # failures plus the flaky tests detected in this
		    # invocation of Abe.  We use the output for $new_flaky.

		    # Check if we have any new FAILs or PASSes compared
		    # to the previous iteration.
		    # Detect PASS->FAIL flaky tests.
		    local res_new_fails_for_deciding
		    "$validate_failures" \
			--manifest="$known_flaky_and_fails_for_deciding" \
			--build_dir="${builddir}$dir" \
			--verbosity=1 "${expiry_date_opt[@]}" \
			> "$new_fails_for_deciding" &
		    res_new_fails_for_deciding=0 && wait $! \
			    || res_new_fails_for_deciding=$?

		    # Detect FAIL->PASS flaky tests.
		    local res_new_passes_for_deciding
		    "$validate_failures" \
			--manifest="$known_flaky_and_fails_for_deciding" \
			--build_dir="${builddir}$dir" \
			--verbosity=1 "${expiry_date_opt[@]}" \
			--inverse_match \
			> "$new_passes_for_deciding" &
		    res_new_passes_for_deciding=0 && wait $! \
			    || res_new_passes_for_deciding=$?

		    # Check again for new FAILs or PASSes compared to the
		    # previous iteration, but this time without considering
		    # the baseline flaky results.

		    # Detect PASS->FAIL flaky tests.
		    local res_new_fails_for_output
		    "$validate_failures" \
			--manifest="$flaky_and_fails_for_output" \
			--build_dir="${builddir}$dir" \
			--verbosity=1 "${expiry_date_opt[@]}" \
			> "$new_fails" &
		    res_new_fails_for_output=0 && wait $! \
			    || res_new_fails_for_output=$?

		    # Detect FAIL->PASS flaky tests.
		    local res_new_passes_for_output
		    "$validate_failures" \
			--manifest="$flaky_and_fails_for_output" \
			--build_dir="${builddir}$dir" \
			--verbosity=1 "${expiry_date_opt[@]}" \
			--inverse_match \
			> "$new_passes" &
		    res_new_passes_for_output=0 && wait $! \
			    || res_new_passes_for_output=$?

		    # If it was the first try and it didn't fail, we don't
		    # need to save copies of the sum and log files.
		    if [ $try = 0 ] \
			   && [ $res_new_fails_for_deciding = 0 ] \
			   && [ $res_new_passes_for_deciding = 0 ]; then
			break
		    fi

		    # Produce this dir's part of $new_try_fails, that will
		    # become $prev_try_fails on the next iteration.
		    notice "New failed tests in this run:"
		    local res_prev_fails
		    "$validate_failures" \
			--build_dir="${builddir}$dir" --produce_manifest \
			--manifest="$dir_fails" --force --verbosity=1 &
		    res_prev_fails=0 && wait $! || res_prev_fails=$?

		    # Find sum and log files from this try and save them.
		    local log sum
		    while IFS= read -r -d '' sum; do
			log="${sum/.sum/.log}"

			mv "$sum" "${sum}.${try}"
			mv "$log" "${log}.${try}"

			sums["$sum"]+="${sum}.${try};"
		    done < <(find "${builddir}$dir" -name '*.sum' -print0)

		    if [ $res_new_fails_for_deciding = 0 ] \
			   && [ $res_new_passes_for_deciding = 0 ]; then
			# No failures. We can stop now.
			break
		    elif [ $res_new_fails_for_deciding = 0 ] \
			     && [ $res_new_passes_for_deciding = 2 ] \
			     && [ $res_prev_fails = 0 ]; then
			:
		    elif [ $res_new_fails_for_deciding = 2 ] \
			     && [ $res_new_passes_for_deciding = 0 ] \
			     && [ $res_prev_fails = 0 ]; then
			:
		    elif [ $res_new_fails_for_deciding = 2 ] \
			     && [ $res_new_passes_for_deciding = 2 ] \
			     && [ $res_prev_fails = 0 ]; then
			:
		    else
			# Exit code 2 means that the result comparison
			# found regressions.
			#
			# Exit code 1 means that the script has failed
			# to process .sum files. This likely indicates
			# malformed or very unusual results.
			warning "$validate_failures had an unexpected error."
			result=1
			break
		    fi
		    more_tests_to_try=true

		    if [ $try != 0 ]; then
			# Incorporate this try's flaky tests into $new_flaky.
			# This will make these tests appear in
			# $known_flaky_and_fails_for_deciding and
			# $flaky_and_fails_for_output for the next iteration.
			if [ $res_new_fails_for_output = 2 ]; then
			    # Prepend "flaky | " attribute to
			    # the newly-detected flaky tests.
			    sed -i -e "s#^\([A-Z]\+: \)#flaky | \1#" \
				"$new_fails"

			    cat "$new_fails" >> "$new_flaky"
			    notice "Detected new PASS->FAIL flaky tests:"
			    cat "$new_fails"
			fi
			if [ $res_new_passes_for_output = 2 ]; then
			    # Prepend "flaky | " attribute to
			    # the newly-detected flaky tests.
			    sed -i -e "s#^\([A-Z]\+: \)#flaky | \1#" \
				"$new_passes"

			    cat "$new_passes" >> "$new_flaky"
			    notice "Detected new FAIL->PASS flaky tests:"
			    cat "$new_passes"
			fi
		    fi
		    cat "$dir_fails" >> "$new_try_fails"

		    readarray -t failed_exps_for_dir \
                              < <(cat "$new_fails_for_deciding"  \
				      "$new_passes_for_deciding" \
				      | awk '/^Running .* \.\.\./ { print $2 }'\
				      | sort -u)

		    if [ ${#failed_exps_for_dir[@]} -eq 0 ]; then
			# This indicates a bug in validate_failures.py.
			warning "$validate_failures failed: it reported regressions but no failed tests."
			result=1
			break;
		    fi

		    failed_exps+=("${failed_exps_for_dir[@]}")

		    break
		done # inner while true
	    done # $dir loop
	done # $tool loop
	notice "Finished testsuite run #$try."
        record_test_results "${component}" $2
	try=$((try + 1))
	cp "$new_try_fails" "$prev_try_fails"
	true > "$new_try_fails"
    done # outer while true

    # If there was more than one try, we need to merge all the sum files.
    if [ $try -ne 0 ]; then
	for sum in "${!sums[@]}"; do
	    local -a sum_tries=()
	    IFS=";" read -r -a sum_tries <<< "${sums[$sum]}"

	    "${gcc_compare_results}/compare_dg_tests.pl" \
		--merge -o "${sum}" "${sum_tries[@]}"
	done
    fi

    rm "$new_fails" "$new_passes" "$baseline_flaky"
    rm "$new_fails_for_deciding" "$new_passes_for_deciding"
    rm "$known_flaky_and_fails_for_deciding" "$flaky_and_fails_for_output"
    if [ "$flaky_failures" = "" ]; then
	rm "$new_flaky"
    fi
    rm "$prev_try_fails" "$new_try_fails" "$dir_fails"

    if [ x"$ldso_bin" != x"" ] && $exec_tests; then
        rm -rf ${sysroots}/libc/etc/ld.so.cache
    fi

    if $exec_tests && [ x"$test_container" != x"" ]; then
	print_make_opts_and_copy_sysroot "$test_container" "restore"
	if [ $? -ne 0 ]; then
	    error "Cannot restore sysroot on $test_container"
	    return 1
	fi
    fi

    if [ $result != 0 ]; then
	error "Making check in ${builddir} failed"
	return 1
    fi

    if test x"${component}" = x"gcc"; then
	# If the user provided send_results_to, send the results
	# via email, or via a filter
	if [ x"$send_results_to" != x ]; then
	    local srcdir="$(get_component_srcdir ${component})"
	    # Hack: Remove single quotes (octal 047) in
	    # TOPLEVEL_CONFIGURE_ARGUMENTS line in config.status,
	    # to avoid confusing test_summary. Quotes are added by
	    # configure when srcdir contains special characters,
	    # including '~' which ABE uses.
	    dryrun "(cd ${builddir} && sed -i -e '/TOPLEVEL_CONFIGURE_ARGUMENTS/ s/\o047//g' config.status)"
	    dryrun "(cd ${builddir} && ${srcdir}/contrib/test_summary -t -m ${send_results_to} | sed s\|Mail\|${send_results_filter}\| | sh)"
	fi
    fi

    return 0
    )
}

make_clean()
{
#    trace "$*"

    local component=$1
    local builddir="$(get_component_builddir ${component} $2)"

    notice "Making clean in ${builddir}"
    dryrun "make clean -w -C ${builddir}"
    if test $? != "0"; then
        warning "Make clean failed!"
    fi

    return 0
}

make_docs()
{
#    trace "$*"

    local component=$1
    local builddir="$(get_component_builddir ${component} $2)"

    notice "Making docs in ${builddir}"

    local make_flags=""

    local logfile="${builddir}/make-${component}${2:+-$2}.log"
    local docs="install-html install-info"

    if [ "${full_docs}" = "yes" ]; then
	docs="${docs} install-pdf install-dvi"
    fi

    case $1 in
        *binutils*)
            # the diststuff target isn't supported by all the subdirectories,
            # so we build both all targets and ignore the error.
            record_artifact "log_makedoc_${component}${2:+-$2}" "${logfile}"
	    dryrun "echo NOTE: Installing docs in ${builddir} | tee -a ${logfile}"
	    for subdir in bfd binutils gas gold gprof gprofng ld
	    do
		# Some configurations want to disable some of the
		# components (eg gold), so ${build}/${subdir} may not
		# exist. Skip them in this case.
		if [ -d ${builddir}/${subdir} ]; then
		    local man_target="diststuff install-man"
		    # gprofng does not support "diststuff"
		    if [ "$subdir" = "gprofng" ]; then
			man_target="install-man"
		    fi
		    dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir}/${subdir} ${man_target} 2>&1 | tee -a ${logfile}"
		    if test $? -ne 0; then
			error "make docs failed in ${subdir}"
			return 1;
		    fi
		fi
	    done
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir} ${docs} 2>&1 | tee -a ${logfile}"
	    if test $? -ne 0; then
		error "make docs failed"
		return 1;
	    fi
            return 0
            ;;
        *gdbserver)
            return 0
            ;;
        *gdb)
	    record_artifact "log_makedoc_${component}${2:+-$2}" "${logfile}"
            dryrun "echo NOTE: Installing docs in ${builddir} | tee -a ${logfile}"
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir}/gdb diststuff ${docs} 2>&1 | tee -a ${logfile}"
	    if test $? -ne 0; then
		error "make docs failed"
		return 1;
	    fi
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir}/gdb/doc install-man 2>&1 | tee -a ${logfile}"
	    if test $? -ne 0; then
		error "make docs failed"
		return 1;
	    fi
            return 0
            ;;
        *gcc*)
	    record_artifact "log_makedoc_${component}${2:+-$2}" "${logfile}"
            dryrun "echo NOTE: Installing docs in ${builddir} | tee -a ${logfile}"
	    for subdir in gcc ${target}/libstdc++-v3
	    do
		# Some configurations want to disable some of the
		# components, so ${build}/${subdir} may not
		# exist. Skip them in this case.
		if [ -d ${builddir}/${subdir} ]; then
		    dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir}/${subdir} install-man 2>&1 | tee -a ${logfile}"
		    if test $? -ne 0; then
			error "make docs failed in ${subdir}"
			return 1;
		    fi
		fi
	    done
	    dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir} ${docs} 2>&1 | tee -a ${logfile}"
	    if test $? -ne 0; then
		error "make docs failed"
		return 1;
	    fi
            return 0
            ;;
        *linux*|*dejagnu*|*gmp*|*mpc*|*mpfr*|*newlib*|*make*)
            # the regular make install handles all the docs.
            ;;
        glibc|eglibc)
	    record_artifact "log_makedoc_${component}${2:+-$2}" "${logfile}"
            dryrun "echo NOTE: Installing docs in ${builddir} | tee -a ${logfile}"
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir} info html 2>&1 | tee -a ${logfile}"
	    if test $? -ne 0; then
		error "make docs failed"
		return 1;
	    fi
            return 0
            ;;
	qemu)
	    return 0
	    ;;
        *)
	    record_artifact "log_makedoc_${component}${2:+-$2}" "${logfile}"
            dryrun "echo NOTE: Installing docs in ${builddir} | tee -a ${logfile}"
            dryrun "make SHELL=${bash_shell} ${make_flags} -w -C ${builddir} info man 2>&1 | tee -a ${logfile}"
	    if test $? -ne 0; then
		error "make docs failed"
		return 1;
	    fi
            return 0
            ;;
    esac

    return 0
}

# See if we can link a simple executable
hello_world()
{
#    trace "$*"

    if test ! -e /tmp/hello.cpp; then
    # Create the usual Hello World! test case
    cat <<EOF > /tmp/hello.cpp
#include <iostream>
int
main(int argc, char *argv[])
{
    std::cout << "Hello World!" << std::endl; 
}
EOF
    fi

    # Make sure we have C flags we need to link successfully
    local extra_cflags=
    case "${clibrary}/${target}/${multilib}" in
        newlib/arm*/rmprofile)
          extra_cflags="-mcpu=cortex-m3 --specs=rdimon.specs"
          ;;
        newlib/arm*/aprofile)
          extra_cflags="-mcpu=cortex-a8"
          ;;
        newlib/aarch64*-elf)
          extra_cflags="--specs=rdimon.specs"
          ;;
        newlib/*)
	  # FIXME: Enable hello-world test for aarch64-w64-mingw32 once
	  # it supports C++.
          notice "Hello world test not supported for newlib on ${target}"
          return 0
          ;;
    esac

    # See if a test case compiles to a fully linked executable.
    if [ x"$build" = x"$host" ]; then
        dryrun "$prefix/bin/${target}-g++ ${extra_cflags} -o /tmp/hi /tmp/hello.cpp"
        if test -e /tmp/hi; then
            rm -f /tmp/hi
        else
            return 1
        fi
    fi

    return 0
}

# Copy compiler libraries to sysroot
copy_gcc_libs_to_sysroot()
{
    local ldso_must_exist=true
    local libgcc
    local ldso
    local gcc_lib_path
    local sysroot_lib_dir

    if [ x"$clibrary" = x"newlib" ]; then
	# Newlib is normally used for bare-metal builds, so no ld.so expected.
	# Still, one could use newlib for linux builds
	ldso_must_exist=false
    fi

    ldso=$(find_dynamic_linker $ldso_must_exist)

    if [ x"$ldso" != x"" ]; then
	libgcc="libgcc_s.so"
    elif $ldso_must_exist; then
	return 1
    else
	libgcc="libgcc.a"
    fi

    # Make sure the compiler built before trying to use it
    if test ! -e $prefix/bin/${target}-gcc; then
	error "${target}-gcc doesn't exist!"
	return 1
    fi
    libgcc="$($prefix/bin/${target}-gcc -print-file-name=${libgcc})"
    if [ x"$libgcc" = x"libgcc_s.so" -o x"$libgcc" = x"libgcc.a" ]; then
	error "Cannot find libgcc: $libgcc"
	return 1
    fi
    gcc_lib_path="$(dirname "${libgcc}")"
    if [ x"$ldso" != x"" ]; then
	sysroot_lib_dir="$(dirname ${ldso})"
    else
	sysroot_lib_dir="${sysroots}/lib"
    fi

    rsync -a ${gcc_lib_path}/ ${sysroot_lib_dir}/
}

# Copy compiler libraries to build dir
copy_gcc_libc_to_builddir()
{
    local builddir=$1
    local libgcc
    local libstdcpp

    # NB: some architectures (m68k, hppa) uses a different libgcc
    # minor version than default '1'.
    local libgccname="libgcc_s.so.1"
    local libstdcppname="libstdc++.so.6"

    local prefix
    # Set by abe.sh when --target is set.
    if [ ! -z "${target_set}" ]; then
      prefix="${target}-"
    fi

    libgcc="$(${prefix}gcc -print-file-name=$libgccname)"
    if [ x"$libgcc" = x"$libgccname" ]; then
	error "Cannot find libgcc: $libgcc"
	return 1
    fi
    libstdcpp="$(${prefix}gcc -print-file-name=$libstdcppname)"
    if [ x"$libstdcpp" = x"$libstdcppname" ]; then
	error "Cannot find libstdc++: $libstdcpp"
	return 1
    fi

    # The libstdc++.so.6 is usually a symlink to a minor version.
    rsync -aL $libgcc $libstdcpp $builddir
}

# helper function for record_test_results(). Records .sum files as artifacts
# for components which use dejagnu for testing.
record_sum_files()
{
    local component=$1
    local builddir="$(get_component_builddir ${component} $2)"

    local time=$SECONDS
    # files/directories could have any weird chars in, so take care to
    # escape them correctly
    local i
    for i in $(find "${builddir}" -name "*.sum" -exec \
		    bash -c 'printf "$@"' bash '%q\n' {} ';' ); do
	record_artifact "dj_sum_${component}${2:+-$2}" "${i}"
    done
    notice "Finding artifacts took $((SECONDS-time)) seconds"
}

# record_test_results() is used to record the artifacts generated by
# make check.
record_test_results()
{
    local component=$1
    local subcomponent=$2

    # no point in incurring the cost of $(find) if we don't need the
    # results.
    if [ "${list_artifacts:+set}" != "set" -o x"${dryrun}" = xyes ]; then
        notice "Skipping search for test results."
        return 0
    fi

    case "${component}" in
        binutils|gcc|gdb|newlib)
            # components which use dejagnu for testing, and generate .sum
            # files during make check. It is assumed that the location of .log
            # files can be derived by the consumer of the artifacts list.
            record_sum_files "${component}" ${subcomponent}
            ;;
        *)
            # this component doesn't have test results (yet?)
            return 0
            ;;
    esac
    return 0
}
