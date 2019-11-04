#!/bin/bash
# Version: 0.1.11

# this will make curl work with https
export NSS_DISABLE_HW_GCM=1

# adding this for mssql tools
export ACCEPT_EULA=Y

# all output goes to syslog (/usr/log/messages), duplicated to stderr
exec > >(logger -s -t dba-bootstrap)
exec 2> >(logger -s -t nimbul3-bootstrap)

set -ux
set -o pipefail

function install_aws_cli(){
  /usr/bin/wget -P /tmp https://s3.amazonaws.com/aws-cli/awscli-bundle.zip
  [ -f /tmp/awscli-bundle.zip ] || exit 1
  /usr/bin/unzip -o /tmp/awscli-bundle.zip -d /tmp && /tmp/awscli-bundle/install -i /usr/local/aws -b /usr/local/bin/aws
}

if ps ax | /bin/grep "puppet apply" | /bin/grep -v grep > /dev/null 2>&1; then
  echo "Puppet apply script is running. Exiting."
  exit 1
fi

# Goodbye spacewalk that never was setup by infra
rm -f /etc/yum.repos.d/spacewalk*

# Enable RHEL yum plugins
if /bin/grep "Red Hat Enterprise Linux" /etc/redhat-release >/dev/null 2>&1; then
    aws_region="$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document| grep '"region" :*' |awk -F\" '{print $4}') 2>/dev/null"
    if [ -n "${aws_region}" ]; then
        for p in redhat-rhui-client-config.repo redhat-rhui.repo; do
            if [ -f "/etc/yum.repos.d/${p}" ]; then
                echo "Setting AWS region for rhui repo: ${p}"
                pattern="s/REGION/${aws_region}/g"
                sed -i "${pattern}" "/etc/yum.repos.d/${p}"
            fi
        done
    fi
else
    # Temporary fix due to broken mirror in yum mirror list
    sed -i  's/^mirrorlist/#mirrorlist/g' /etc/yum.repos.d/*.repo
    sed -i  's/^#baseurl/baseurl/g' /etc/yum.repos.d/*.repo
fi

# install new puppet from puppetlabs, it supports s3_enabled for yumrepo command !!!
# TODO: need better check, if yum install puppet fails, re-bootstraps will fail at rpm -u
if [[ ! -f /usr/bin/puppet ]]; then
    rpm -ivh https://yum.puppetlabs.com/el/6/products/x86_64/puppetlabs-release-6-11.noarch.rpm
    yum -y install puppet
fi

# installing svn in the bootstrap because puppet needs it for content generators
yum -y install subversion git lvm2 vim rubygem-deep_merge

# # stopping nrpe in order to run nagios puppet code.
# /sbin/service nrpe stop
#
# force nrpe to stop
/usr/bin/killall nrpe

# sed -i "s/http\:\/\/169.254.169.254\/latest\/user\-data/\-H \'Metadata-Flavor:Google\' \"http:\/\/169.254.169.254\/computeMetadata\/v1\/instance\/attributes\/\?recursive\=true\&alt\=text\" \| awk \'\{print \$1 \"\=\" \$2\}\'/" /etc/facter/facts.d/user_data.sh

platform="gcp"
aws_facts="/etc/facter/facts.d/user_data.sh"
mkdir -p $(dirname $aws_facts)

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
echo "aws_region=\$\{aws_region:-\}"
echo "aws_instance_type=\$\{aws_region:-\}"
EOF
fi

chmod +x $aws_facts

# load the same facts as env variables
source <($aws_facts)

# bypass unbound variable exception when aws_template_code is not set by user_data
set +u
aws_template_code="${aws_template_code}"
set -u

# download our puppet modules to standard location
puppet_dir=/usr/share/puppet
rpms_dir=/usr/share/rpms
keys_dir=/usr/share/keys

mkdir -p "${rpms_dir}"
mkdir -p "${keys_dir}"

# xvdisks=0

diskscheme="xvdisks"
sddisks=$(/bin/ls -1 /dev/sd* 2>/dev/null | wc -l 2>/dev/null)
if ((sddisks > 0)); then
    diskscheme="sddisks"
fi

oracle_pattern="\\boracle\\b"

if [ -n "${aws_template_code}" ]; then
  s3_root="s3://infrastructure-templates-nyt-net/${aws_template_code}/${aws_environment_code}"
  if [[ "${aws_template_code}" =~ mysql ]]; then
    database="mysql"
    if [[ ${diskscheme} == "sddisks" ]]; then
        configured_disk_count=3
        [[ "$platform" == 'aws' ]] && disk_array=jkl || disk_array=bcd
    else
        configured_disk_count=4
        [[ "$platform" == 'aws' ]] && disk_array=fghi || disk_array=bcde
    fi
  elif [[ "${aws_template_code}" =~ mongodb ]]; then
    database="mongodb"
    configured_disk_count=2
    if [[ "$platform" == 'aws' ]]; then
      disk_array=jk
    else
      disk_array=bc
    fi
  elif [[ "${aws_template_code}" =~ postgres ]]; then
    database="postgres"
    configured_disk_count=5
    [[ "$platform" == 'aws' ]] && disk_array=jklmn || disk_array=bcdef
  elif [[ "${aws_template_code}" =~ $oracle_pattern ]]; then
    # xvdisks=1
    database="oracle"
    configured_disk_count=3
    [[ "$platform" == 'aws' ]] && disk_array=fgh || disk_array=fgh
  else
    database="mysql"
    configured_disk_count=3
    [[ "$platform" == 'aws' ]] && disk_array=jkl || disk_array=bcd
  fi
else
  s3_root="s3://infrastructure-deploy-nyt-net/dba/${aws_environment_code}"
  case "${aws_cluster_code}" in
    db)
      database="mysql"
      configured_disk_count=4
      # xvdisks=1
      [[ "$platform" == 'aws' ]] && disk_array=jkl || disk_array=bcd
    ;;
    rs)
      database="mongodb"
      configured_disk_count=2
      if [[ "$platform" == 'aws' ]]; then
        disk_array=jk
      else
        disk_array=bc
      fi
    ;;
    pg)
      database="postgres"
      configured_disk_count=5
      [[ "$platform" == 'aws' ]] && disk_array=jklmn || disk_array=bcdef
    ;;
	ora)
      database="oracleclient"
      configured_disk_count=1
      [[ "$platform" == 'aws' ]] && disk_array=j || disk_array=b
    ;;
    oraos)
      # xvdisks=1
      database="oracle"
      configured_disk_count=3
      [[ "$platform" == 'aws' ]] && disk_array=fgh || disk_array=fgh
    ;;
    jump)
      database="mysql"
      configured_disk_count=4
      disk_array=fghi
    ;;
    *)
      database="mysql"
      configured_disk_count=0
    ;;
  esac
fi

s3_puppet_home="${s3_root}/orchestration/puppet"
s3_rpms_home="${s3_root}/configuration/rpms/repo/x86_64"
s3_keys_home="${s3_root}/configuration/keys"

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
  # xvdisks=1
else
  if [[ "${database}" == "mysql" ]]; then
    instance_size="tiny"
  else
    instance_size="small"
  fi
fi

if [[ "${diskscheme}" == "xvdisks" ]]; then
  case "${database}" in
    mysql)    disk_array="fghi";;
    mongodb)  disk_array="fg";;
    postgres) disk_array="fghij";;
	  oracleclient) disk_array="f";;
    oracle) disk_array="fgh";;
  esac
fi

database_facts="/etc/facter/facts.d/database.sh"

# facter file to expose specific database configuration data from user-data as puppet facts
cat <<-EOF > $database_facts
#!/bin/bash

echo platform="${platform}"
echo database="${database}"
echo diskscheme="${diskscheme}"
echo database_instance_size="${instance_size}"
EOF

chmod 755 $database_facts

cluster_facts="/etc/facter/facts.d/cluster.sh"

cluster_json=$(/usr/bin/curl -H 'Authorization: Token token="7243d1f7c30b96f51e43f413dd0a1889"' https://nimbul.prd.nytimes.com/api/v1/clusters 2>/dev/null)
mysql_clusters="dba-db,$(echo "${cluster_json}" | /usr/bin/jq '.[] | select(.template_code | contains("mysql")) |  "\(.app_code)-\(.code)" ' 2>/dev/null | /bin/sort | /usr/bin/xargs | /usr/bin/tr ' ' ',' 2>/dev/null)"
mongodb_clusters="dba-rs,$(echo "${cluster_json}" | /usr/bin/jq '.[] | select(.template_code | contains("mongodb")) |  "\(.app_code)-\(.code)" ' 2>/dev/null | /bin/sort | /usr/bin/xargs | /usr/bin/tr ' ' ',' 2>/dev/null)"
postgres_clusters="dba-pg,$(echo "${cluster_json}" | /usr/bin/jq '.[] | select(.template_code | contains("postgres")) |  "\(.app_code)-\(.code)" ' 2>/dev/null | /bin/sort | /usr/bin/xargs | /usr/bin/tr ' ' ',' 2>/dev/null)"
oracleclient_clusters="dba-ora"
oracle_clusters="dba-oraos,$(echo "${cluster_json}" | /usr/bin/jq '.[] | select(.template_code | contains("oracle")) |  "\(.app_code)-\(.code)" ' 2>/dev/null | /bin/sort | /usr/bin/xargs | /usr/bin/tr ' ' ',' 2>/dev/null)"

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

if [[ "$platform" == 'gcp' ]]; then
  machine_facts="/etc/facter/facts.d/machine.sh"
  gcp_machine_type=$(/usr/bin/curl -fs -H 'Metadata-Flavor:Google' "http://169.254.169.254/computeMetadata/v1/instance/machine-type" 2>/dev/null | awk -F '/' '{print $NF}' 2>/dev/null)

  cat <<-EOF > $machine_facts
  #!/bin/bash

  echo gcp_machine_type="${gcp_machine_type}"
EOF
fi


# Y U NO S3 SYNC?
#
# According to https://github.com/aws/aws-cli/issues/599, "...if the
# file sizes are the same and the last modified time in s3 is greater
# (newer) than the local file, then we don't sync. This is the current
# behavior."  So this is a problem for us when we push puppet files
# that keep the same size, think "dev" changed to "prd".
#aws s3 cp --recursive $s3_root/puppet $puppet_dir
#aws s3 sync ${s3_root}/rpms/x86_64/ $rpms_dir --exclude "*" --include "rubygem*"
aws s3 cp --recursive "${s3_puppet_home}" "${puppet_dir}"
aws s3 sync "${s3_rpms_home}" "${rpms_dir}" --exclude "*" --include "rubygem*"
aws s3 sync "${s3_keys_home}" "${keys_dir}"

rm -f /etc/hiera.yaml
if [ ! -L "/etc/puppet/hiera.yaml" ]; then
  ln -s /usr/share/puppet/config/hiera.yaml /etc/puppet/hiera.yaml
fi
if [ ! -L "/etc/puppet/hieradata" ]; then
  ln -s /usr/share/puppet/config/hieradata /etc/puppet/hieradata
fi

chmod -R 700 /usr/share/puppet/scripts

# mkdir -p /root/.ssh
# chmod 700 /root/.ssh
#
# cat << EOF > /root/.ssh/config
# Host git.em.nytimes.com
#   IdentityFile /root/.ssh/deployer_nomad_${aws_environment_code}
#   StrictHostKeyChecking no
# EOF
#
# chmod 600  /root/.ssh/config

# /usr/share/puppet/scripts/s3fetch.sh -t mysql/${aws_environment_name,,}/common/deployer_nomad_${aws_environment_code} > /root/.ssh/deployer_nomad_${aws_environment_code}
# chmod 600  /root/.ssh/deployer_nomad_${aws_environment_code}

# /usr/share/puppet/scripts/s3fetch.sh -t dbas/puppetmaster.key > /tmp/pm.key
/usr/bin/gpg --import ${keys_dir}/gpg/*.key

rpm -ivh ${rpms_dir}/*.rpm

# leave this because Ben is going to replace the line for GCP prebootstraping
#prebootstrap script

#if ((configured_disk_count > 0)); then
#    if [[ "${diskscheme}" == "xvdisks" ]]; then
#      attached_disk_count=$(ls -la /dev/xvd[$disk_array] 2>/dev/null | wc -l 2>/dev/null)
#      while ((attached_disk_count != configured_disk_count)); do
#        echo 'Waiting for configured devices to attach...' >&2
#        sleep 1
#        attached_disk_count=$(ls -la /dev/xvd[$disk_array] 2>/dev/null | wc -l 2>/dev/null)
#      done
#    else
#      attached_disk_count=$(ls -la /dev/sd[$disk_array] 2>/dev/null | wc -l 2>/dev/null)
#      while ((attached_disk_count != configured_disk_count)); do
#        echo 'Waiting for configured devices to attach...' >&2
#        sleep 1
#        attached_disk_count=$(ls -la /dev/sd[$disk_array] 2>/dev/null | wc -l 2>/dev/null)
#      done
#    fi
#fi
#  execute the puppet module for our app and cluster
# puppet apply -e "include ${aws_app_code}_${aws_cluster_code}" --color false --verbose
# puppet manifests/site.pp --color false --verbose
puppet apply /usr/share/puppet/manifests/site.pp --environment ${aws_environment_name,,} --confdir /usr/share/puppet/config --color false --verbose --detailed-exitcodes || {
     # handle bug https://tickets.puppetlabs.com/browse/PUP-2754 where puppet doesn't report exit codes as expected
     # The code below deals with behavior of --detailed-exitcodes
     puppet_status=$?
     if [ $puppet_status -eq 2 ]; then
         echo "Puppet Changes Applied"
         puppet_status=0
     elif [ $puppet_status -eq 4 -o $puppet_status -eq 6 ]; then
         echo "Puppet failures detected"
     else
         echo "Warning: unexpected puppet exit code returned"
     fi
     exit $puppet_status
 }
