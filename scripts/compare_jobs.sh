#!/bin/bash

mydir="`dirname $0`"
status=0

if [ $# != 2 ]
then
    echo "Usage: $0 ref_logs new_logs"
    exit 1
fi

ref_logs=$1
new_logs=$2

tmptargets=/tmp/targets.$$
trap "rm -f ${tmptargets}" 0 1 2 3 5 9 13 15

rm -f ${tmptargets}

function xml_report_print_row
{
    local target=${1?}
    local failed=${2?}
    local log_url=BUILD_URL/artifact/artifacts/logs/diff-${target}.txt
    local color='#00FF00'
    $failed && color='#FF0000'
    local message=PASSED
    $failed && message=FAILED
    cat <<EOF
<tr>
  <td>${target}</td>
  <td fontattribute="bold" bgcolor="${color}">${message}</td>
  <td><![CDATA[<a href="$log_url">log for ${target}</a>]]></td>
</tr>
EOF
}

function xml_report_print_header
{
    cat <<EOF
<section name="Results comparison ${ref_logs} vs ${new_logs}"><table>
  <tr>
  <td fontattribute="bold" width="120" align="center">Target</td>
  <td fontattribute="bold" width="120" align="center">Status</td>
  <td fontattribute="bold" width="120" align="center">Log</td>
</tr>
EOF
}

function xml_report_print_footer
{
    cat <<EOF
</table></section>
EOF
}

function xml_log_print_field
{
    local target=${1?}
    local log=${2?}
    cat <<EOF
  <field name="${target}">
    <![CDATA[
EOF
cat $log
cat <<EOF
    ]]></field>
EOF
}

function xml_log_print_header
{
    cat <<EOF
<section name="Logs">
EOF
}

function xml_log_print_footer
{
    cat <<EOF
</section>
EOF
}

# For the time being, we expect different jobs to store their results
# in similar directories.

# Build list of all build-targets validated for ${ref_logs}
# Use grep -v '*' to skip the case where the first regexp does not
# match any directory.
for dir in `echo ${ref_logs}/* | grep -v '*'`
do
    basename ${dir} >> ${tmptargets}
done

# Build list of all build-targets validated for ${new_logs}
for dir in `echo ${new_logs}/* | grep -v '*'`
do
    basename ${dir} >> ${tmptargets}
done

if [ -s ${tmptargets} ]; then
    buildtargets=`sort -u ${tmptargets}`
fi
rm -f ${tmptargets}

XML_REPORT=${mydir}/report0.xml
rm -f ${XML_REPORT} ${XML_REPORT}.part
XML_LOG=${mydir}/report1.xml
rm -f ${XML_LOG} ${XML_LOG}.part

xml_report_print_header > ${XML_REPORT}.part
xml_log_print_header > ${XML_LOG}.part

for buildtarget in ${buildtargets}
do
    ref=`echo ${ref_logs}/${buildtarget} | grep -v '*'`
    build=`echo ${new_logs}/${buildtarget} | grep -v '*'`
    echo "REF = ${ref_logs}"
    echo "BUILD = ${new_logs}"
    failed=false
    mylog=${mydir}/diff-${buildtarget}.txt
    target=`echo ${buildtarget} | cut -d. -f2`
    printf "\t# ============================================================== #\n" > ${mylog}
    printf "\t#\t\t*** ${buildtarget} ***\n" >> ${mylog}
    printf "\t# ============================================================== #\n\n" >> ${mylog}
    [ ! -z "${build}" -a ! -z "${ref}" ] && ${mydir}/compare_tests -target ${target} \
	${ref} ${build} >> ${mylog} || failed=true

    ${failed} && status=1
    xml_report_print_row "${buildtarget}" "${failed}" >> $XML_REPORT.part
    xml_log_print_field "${buildtarget}" ${mylog} >> $XML_LOG.part
done

xml_report_print_footer >> ${XML_REPORT}.part
xml_log_print_footer >> ${XML_LOG}.part
mv ${XML_REPORT}.part ${XML_REPORT}
mv ${XML_LOG}.part ${XML_LOG}

exit ${status}
