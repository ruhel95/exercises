#!/bin/bash

aws_facts="/etc/facter/facts.d/user_data.sh"
database_facts="/etc/facter/facts.d/database.sh"
cluster_facts="/etc/facter/facts.d/cluster.sh"

if [[ "$(hostname -f)" =~ chs[[:digit:]]|oma[[:digit:]] ]]; then
# gcp_hostname_pattern="\.internal$"
# if [[ "$(hostname -f)" =~ $gcp_hostname_pattern ]]; then
  platform="gcp"
else
  platform="aws"
fi

if [[ "$platform" == "aws" ]]; then
  cat >$aws_facts <<EOF
#!/bin/bash

# turns AWS user-data as Facts to be used by puppet
# prefix all names with "aws_",  quote all values with spaces

curl -fs http://169.254.169.254/latest/user-data |\\
  sed 's/^/aws_/' |\\
  sed 's/=\\(.*[ \\t].*\\)/="\\1"/'

#Add a newline after the last of the modified curl'ed vars
echo

#Throw in region - user-data only defines region_code, not the region - but we can get that from the
#identity document.  Implemented as a param default just in case it pops up in user-data sometime
echo "aws_region=\${aws_region:-$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document| grep '"region" :*' |awk -F\" '{print $4}')}"
echo "aws_instance_type=\${aws_region:-$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document| grep '"instanceType" :*' |awk -F\" '{print $4}')}"
EOF
else
  cat >$aws_facts <<"EOF"
#!/bin/bash

# turns AWS user-data as Facts to be used by puppet
# prefix all names with "aws_",  quote all values with spaces

data=$(curl -fs -H 'Metadata-Flavor:Google' "http://169.254.169.254/computeMetadata/v1/instance/attributes/?recursive=true")

/usr/bin/jq "to_entries | .[] | select(.value | contains(\" \")) | \"aws_\" + .key + \"='\" + .value + \"'\" " -r <(echo "$data")
/usr/bin/jq "to_entries | .[] | select(.value | contains(\" \") | not) | \"aws_\" + .key + \"=\" + .value " -r <(echo "$data")

#Add a newline after the last of the modified curl'ed vars
echo

#Throw in region - user-data only defines region_code, not the region - but we can get that from the
#identity document.  Implemented as a param default just in case it pops up in user-data sometime
echo "aws_region=us-east-1"
echo "aws_instance_type=\$\{aws_region:-\}"
EOF
fi

chmod 755 $aws_facts

source <($aws_facts)

oracle_pattern="\\boracle\\b"

if [ -n "${aws_template_code}" ]; then
  if [[ "${aws_template_code}" =~ mysql ]]; then
    database="mysql"
    db_path="/var/nyt/mysql/data"
    dbs_csv="$(/usr/bin/find $db_path -maxdepth 1 -type d -not -path $db_path -exec basename '{}' \; 2>/dev/null | /usr/bin/xargs | /usr/bin/tr ' ' ',')"
  elif [[ "${aws_template_code}" =~ mongodb ]]; then
    database="mongodb"
    db_path="/var/nyt/mongo/data"
    dbs_csv="$(/usr/bin/find $db_path -maxdepth 1 -type d -not \( -path $db_path -o -path $db_path/_tmp -o -path $db_path/journal \) -exec basename '{}' \; 2>/dev/null | /usr/bin/xargs | /usr/bin/tr ' ' ',')"
  elif [[ "${aws_template_code}" =~ postgres ]]; then
    database="postgres"
    db_path="/var/nyt/pgsql/data"
    dbs_csv="$(/bin/ls -1 $db_path 2>/dev/null | /bin/grep -v 'lost+found' | /usr/bin/xargs | /usr/bin/tr ' ' ',')"
  elif [[ "${aws_template_code}" =~ $oracle_pattern ]]; then
    database="postgres"
    db_path="/var/nyt/oracle/data"
    dbs_csv=""
  else
    database="mysql"
    db_path="/var/nyt/mysql/data"
    dbs_csv="$(/usr/bin/find $db_path -maxdepth 1 -type d -not -path $db_path -exec basename '{}' \; 2>/dev/null | /usr/bin/xargs | /usr/bin/tr ' ' ',')"
  fi
else
  if [[ "${aws_cluster_code}" == "db" ]]; then
    database="mysql"
    db_path="/var/nyt/mysql/data"
    dbs_csv="$(/usr/bin/find $db_path -maxdepth 1 -type d -not -path $db_path -exec basename '{}' \; 2>/dev/null | /usr/bin/xargs | /usr/bin/tr ' ' ',')"
  elif [[ "${aws_cluster_code}" == "rs" ]]; then
    database="mongodb"
    db_path="/var/nyt/mongo/data"
    dbs_csv="$(/usr/bin/find $db_path -maxdepth 1 -type d -not \( -path $db_path -o -path $db_path/_tmp -o -path $db_path/journal \) -exec basename '{}' \; 2>/dev/null | /usr/bin/xargs | /usr/bin/tr ' ' ',')"
  elif [[ "${aws_cluster_code}" == "pg" ]]; then
    database="postgres"
    db_path="/var/nyt/pgsql/data"
    dbs_csv="$(/bin/ls -1 $db_path 2>/dev/null  | /bin/grep -v 'lost+found' | /usr/bin/xargs | /usr/bin/tr ' ' ',')"
  elif [[ "${aws_cluster_code}" == "ora" ]]; then
    database="oracleclient"
    db_path="/opt/oracle"
    dbs_csv=""
  elif [[ "${aws_cluster_code}" == "oraos" ]]; then
    database="oracle"
    db_path="/opt/oracle"
    dbs_csv=""
  else
    database="mysql"
    db_path="/var/nyt/mysql/data"
    dbs_csv="$(/usr/bin/find $db_path -maxdepth 1 -type d -not -path $db_path -exec basename '{}' \; 2>/dev/null  | /usr/bin/xargs | /usr/bin/tr ' ' ',')"
  fi
fi

large="\\blarge\\b"
xlarge="\\bxlarge\\b"

if [[ "${aws_instance_configuration_name}" =~ tiny ]]; then
  instance_size="tiny"
elif [[ "${aws_instance_configuration_name}" =~ small ]]; then
  instance_size="small"
elif [[ "${aws_instance_configuration_name}" =~ medium ]]; then
  instance_size="medium"
elif [[ "${aws_instance_configuration_name}" =~ $large ]]; then
  instance_size="large"
elif [[ "${aws_instance_configuration_name}" =~ $xlarge ]]; then
  instance_size="xlarge"
elif [[ "${aws_instance_configuration_name}" =~ custom ]]; then
  instance_size="custom"
elif [[ "${aws_instance_configuration_name}" =~ ultra ]]; then
  instance_size="ultra"
else
  if [[ "${database}" == "mysql" ]]; then
    instance_size="tiny"
  else
    instance_size="small"
  fi
fi


elif [[ "${aws_instance_configuration_name}" =~ $xlarge ]]; then
diskscheme="xvdisks"
sddisks=$(/bin/ls -1 /dev/sd* 2>/dev/null | wc -l 2>/dev/null)
if ((sddisks > 0)); then
    diskscheme="sddisks"
fi

# facter file to expose specific database configuration data from user-data as puppet facts
cat <<-EOF > $database_facts
#!/bin/bash

echo platform="${platform}"
echo database="${database}"
echo diskscheme="${diskscheme}"
echo database_instance_size="${instance_size}"
echo ${database}_dbs="${dbs_csv}"
EOF

chmod 755 $database_facts

cluster_json=$(/usr/bin/curl -H 'Authorization: Token token="1aede41c18225af8071f1953a040f112"' https://nimbul.prd.nytimes.com/api/v1/clusters 2>/dev/null)
mysql_clusters="dba-db,$(echo "${cluster_json}" | /usr/bin/jq '.[] | select(.template_code | contains("mysql")) |  "\(.app_code)-\(.code)" ' 2>/dev/null | /bin/sort | /usr/bin/xargs | /usr/bin/tr ' ' ',' 2>/dev/null)"
mongodb_clusters="dba-rs,$(echo "${cluster_json}" | /usr/bin/jq '.[] | select(.template_code | contains("mongodb")) |  "\(.app_code)-\(.code)" ' 2>/dev/null | /bin/sort | /usr/bin/xargs | /usr/bin/tr ' ' ',' 2>/dev/null)"
postgres_clusters="dba-pg,$(echo "${cluster_json}" | /usr/bin/jq '.[] | select(.template_code | contains("postgres")) |  "\(.app_code)-\(.code)" ' 2>/dev/null | /bin/sort | /usr/bin/xargs | /usr/bin/tr ' ' ',' 2>/dev/null)"
oracleclient_clusters="dba-ora"
oracle_clusters="dba-pg,$(echo "${cluster_json}" | /usr/bin/jq '.[] | select(.template_code | contains("oracle")) |  "\(.app_code)-\(.code)" ' 2>/dev/null | /bin/sort | /usr/bin/xargs | /usr/bin/tr ' ' ',' 2>/dev/null)"

# facter file to expose specific nimbul clusters that are mysql or mongodb database clusters
# TODO: make these structured
cat <<-EOF > $cluster_facts
#!/bin/bash

echo nimbul_mysql_clusters="${mysql_clusters}"
echo nimbul_mongodb_clusters="${mongodb_clusters}"
echo nimbul_postgres_clusters="${postgres_clusters}"
echo nimbul_oracleclient_clusters="${oracleclient_clusters}"
echo nimbul_oracle_clusters="${oracle_clusters}"
EOF

chmod 755 $cluster_facts

exit 0
