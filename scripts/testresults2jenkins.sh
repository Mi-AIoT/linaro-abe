#!/bin/bash

# This script transforms the output of GCC's contrib/test_summary (an
# email) into a format suitable for consumption by our Jenkins CI:
# three files, containing subject, recipient and body.
#
# In order to be used transparently as a replacement for "Mail",
# it uses the same interface as the "Mail" command:
#
# cat body | testresults2jenkins.sh -s "subject" "recipient"
#
# its output goes intro three files:
# - testresults-mail-recipient.txt
# - testresults-mail-subject.txt
# - testresults-mail-body.txt
#
# Because of the fixed interface, we use an environment variable to
# specify the output directory and prefix (TESTRESULTS_PREFIX).

usage()
{
    echo "Usage: $0 -s subject recipient"
    exit 1
}

if [ $# -ne 3 ]; then
    usage
fi

if [ "$1" != "-s" ]; then
    usage
fi

subject="$2"
recipient="$3"

TESTRESULTS_PREFIX=${TESTRESULTS_PREFIX-$(pwd)/testresults-}

echo "to:$recipient" > ${TESTRESULTS_PREFIX}mail-recipient.txt
echo "$subject" > ${TESTRESULTS_PREFIX}mail-subject.txt
cat > ${TESTRESULTS_PREFIX}mail-body.txt
