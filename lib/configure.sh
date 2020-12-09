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

# Configure a source directory
# $1 - the directory to configure
# $2 - [OPTIONAL] which sub component to build (gcc stage)
configure_build()
{
#    trace "$*"

    local component=$1

    # Linux isn't a build project, we only need the headers via the existing
    # Makefile, so there is nothing to configure.
    if test x"${component}" = x"linux"; then
	return 0
    fi
    local srcdir="$(get_component_srcdir ${component})"
    local builddir="$(get_component_builddir ${component} $2)"
    local version="$(basename ${srcdir})"
    local stamp="$(get_stamp_name $component configure ${version} ${2:+$2})"

    # this is a hack for eglibc so that the configure script can be found
    if [ x"${component}" = x"eglibc" ]; then
	srcdir="${srcdir}/libc"
    fi

    # Don't look for the stamp in the builddir because it's in builddir's
    # parent directory.
    local stampdir="$(dirname ${builddir})"

    local ret=
    check_stamp "${stampdir}" ${stamp} ${srcdir} configure ${force}
    ret=$?
    if test $ret -eq 0; then
	return 0 
    elif test $ret -eq 255; then
	# This means that the compare file ${srcdir} is not present.
	return 1
    fi

    if test ! -d "${builddir}"; then
	notice "The build directory '${builddir}' doesn't exist, so creating it"
	dryrun "mkdir -p \"${builddir}\""
    fi

    if test ! -f "${srcdir}/configure" -a x"${dryrun}" != x"yes"; then
	warning "No configure script in ${srcdir}!"
        # not all packages commit their configure script, so if it has autogen,
        # then run that to create the configure script.
	if test -f ${srcdir}/autogen.sh; then
	    (cd ${srcdir} && ./autogen.sh)
	fi
	if test ! -f "${srcdir}/configure"; then
	    error "No configure script in ${srcdir}!"
	    return 1
	fi
    fi

    local opts=""
    local toolname="${component}"
  
    local opts="$(get_component_configure ${component} $2)"

    # Use static linking if component is configured for it
    local static="$(get_component_staticlink ${component})"
    if test x"${static}" = x"yes"; then
	case ${component} in
	    qemu)
		local opts="${opts} --static"
		;;
	    *)
		local opts="${opts} --disable-shared --enable-static"
		;;
	    esac
    fi

    local mingw_extra=$(get_component_mingw_extraconf ${component})
    if is_host_mingw; then
        opts="${opts} ${mingw_extra}"
    fi

    # prefixhost is the root for host-side libs and tools.
    prefixhost="${local_builds}/hosttools/${host}"

    # The release string is usually the date as well, but in YYYY.MM format.
    # For snapshots we add the day field as well.
    if test x"${release}" = x; then
	local date="$(date --date="@${timestamp}" "+%Y.%m")"
    else
	local date="${release}"
    fi

    if test x"${override_cflags}" != x -a x"${component}" != x"eglibc"; then
	local opts="${opts} CFLAGS=\"${override_cflags}\" CXXFLAGS=\"${override_cflags}\""
    fi

    # Some components' configure (eg. qemu's) do not support overriding
    # SHELL via an argument, so allow not to do so when needed.
    FORCESHELL="SHELL=${bash_shell}"

    # GCC and the binutils are the only toolchain components that need the
    # --target option set, as they generate code for the target, not the host.
    case ${component} in
	newlib*|libgloss*)
	    local opts="${opts} --host=${host} --target=${target} --prefix=${sysroots}/usr"
	    ;;
	*libc)
	    # [e]glibc uses slibdir and rtlddir for some of the libraries and
	    # defaults to lib64/ for aarch64.  We need to override this.
	    # There's no need to install anything into lib64/ since we don't
	    # have biarch systems.

	    # libdir is where static libraries and linker scripts are installed,
	    # like libc.so, libc_nonshared.a, and libc.a.
	    echo libdir=/usr/lib > ${builddir}/configparms

	    # slibdir is where shared objects are installed.
	    echo slibdir=/lib >> ${builddir}/configparms

	    # rtlddir is where the dynamic-linker is installed.
	    echo rtlddir=/lib >> ${builddir}/configparms
	    local opts="${opts} --build=${build} --host=${target} --target=${target} --prefix=/usr"
	    dryrun "(mkdir -p ${sysroots}/usr/lib)"
	    ;;
	gcc)
	    local opts="$opts --prefix=$prefix"

	    if test x"$build" != x"$target"; then
		local stage="$2"

		case "$stage" in
			stage1)
			    opts="$opts $stage1_flags"
			    notice "Building stage 1 of GCC"
			    ;;
			stage2)
			    if [ ! -e "$sysroots/libc/usr/include/stdio.h" ]; then
				warning "No sysroot found before gcc stage2 build"
			    fi
			    opts="$opts $stage2_flags"
			    notice "Building stage 2 of GCC"
			    ;;
			*)
			    error "Unknown GCC stage: $stage"
			    ;;
		esac
		opts="$opts --build=$build --host=$host --target=$target"
	    else
		# Native build needs stage2 build only.
		opts="$opts $stage2_flags"
	    fi
	    ;;
	binutils)
	    if test x"${override_linker}" = x"gold"; then
		local opts="${opts} --enable-gold=default"
	    fi
	    local opts="${opts} --build=${build} --host=${host} --target=${target} --prefix=${prefix}"
	    ;;
	gdb)
	    local opts="${opts} --build=${build} --host=${host} --target=${target} --prefix=${prefix}"
	    ;;
	gdbserver)
	    local opts="${opts} --build=${build} --host=${target} --prefix=${sysroots}/usr"
	    ;;
	# These are only built for the host
	gmp|mpc|mpfr|isl|ppl|cloog)
	    local opts="${opts} --build=${build} --host=${host} --prefix=${prefix}"
	    ;;
	# Dejagnu is not a deliverable
	dejagnu)
	    local opts="${opts} --build=${build} --host=${host} --prefix=${prefixhost}"
	    ;;
	qemu)
	    local opts="${opts} --prefix=${prefixhost}"
	    # qemu's configure does not accept a parameter like SHELL=/bin/bash
	    FORCESHELL=""
	    ;;
	*)
	    local opts="${opts} --build=${build} --host=${host} --target=${target} --prefix=${sysroots}/usr"
	    ;;
    esac

    if test -e ${builddir}/config.status -a x"${force}" = xno; then
	warning "${builddir} already configured!"
    else
	if [ x"$component" = x"gdbserver" ]; then
	    # Workaround missing dependency of gdbsupport on BFD.
	    # It'll take a while for binutils-gdb patch to propagate into
	    # releases, so patch code here as a workaround.
	    if ! grep -q "^configure-gdbsupport: maybe-configure-bfd\$" $srcdir/Makefile.in; then
		echo "configure-gdbsupport: maybe-configure-bfd" >> $srcdir/Makefile.in
	    fi
	fi
	# Don't stop on CONFIG_SHELL if it's set in the environment.
	if test x"${CONFIG_SHELL}" = x; then
	    export CONFIG_SHELL=${bash_shell}
	fi
	dryrun "(cd ${builddir} && ${CONFIG_SHELL} ${srcdir}/configure $FORCESHELL ${default_configure_flags} ${opts})"
	if test $? -gt 0; then
	    error "Configure of $1 failed."
	    return 1
	fi

	# unset this to avoid problems later
	unset default_configure_flags
	unset opts
	unset stage1_flags
	unset stage2_flags
    fi

    notice "Done configuring ${component}"

    create_stamp "${stampdir}" "${stamp}"

    return 0
}

