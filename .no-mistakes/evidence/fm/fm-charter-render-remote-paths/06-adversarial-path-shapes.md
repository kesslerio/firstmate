# Adversarial: every remote-home path shape a seed accepts must converge at publish

Each row scaffolds a durable charter naming remote home A
(`FM_SECONDMATE_REMOTE_HOME=A bin/fm-brief.sh mate --secondmate --no-projects`),
then seeds that same id as a LOCAL mate (`bin/fm-home-seed.sh mate <subhome> --no-projects`).
The published charter must carry this parent home's own paths and must not mention A anywhere.

remote home A            | seed exit | A left in published    | local status path hits
-------------------------|-----------|------------------------|----------------------
/srv/homes/ios           | 0         | 0                      | 2
/srv/ho mes/ios          | 0         | 0                      | 2
/srv/[brackets]/ios      | 0         | 0                      | 2
/srv/ho$me/ios           | 0         | 0                      | 2
/srv/ho&me/ios           | 0         | 0                      | 2
/srv/ho*me/ios           | 0         | 0                      | 2
/srv/homes/ios.d         | 0         | 0                      | 2
/srv/homes/ios-2         | 0         | 0                      | 2
/srv/homes/ios/          | 0         | 0                      | 2

cases that did NOT converge: 0
