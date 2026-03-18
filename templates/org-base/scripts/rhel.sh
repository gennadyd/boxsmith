#!/bin/bash -eux
# determine the major EL version we're runninng
major_version="`sed 's/^.\+ release \([.0-9]\+\).*/\1/' /etc/redhat-release | awk -F. '{print $1}'`";
minor_version="`sed 's/^.\+ release \([.0-9]\+\).*/\1/' /etc/redhat-release | awk -F. '{print $2}'`";
pkg_repo="redhat${major_version}-mirror"
pkg_cmd="dnf"

# setup repositories
# remove subscription
for repo in $(subscription-manager repos --list-enabled | grep "Repo ID" | awk -F ":   " '{print $2}'); do
  subscription-manager repos --disable=$repo
done

${pkg_cmd} clean all
rm -f /etc/yum.repos.d/*.repo
rm -rf /var/cache/${pkg_cmd}

cat << EOF > /etc/yum.repos.d/artifactory-mirror.repo
[Artifactory-${pkg_repo}]
name=${pkg_repo}
baseurl=${ARTIFACTORY_URL}/${pkg_repo}
enabled=1
gpgcheck=0
EOF
epel_pkg_repo="epel${major_version}-mirror"
cat << EOF >> /etc/yum.repos.d/artifactory-mirror.repo
[Artifactory-${epel_pkg_repo}]
name=${epel_pkg_repo}
baseurl=${ARTIFACTORY_URL}/${epel_pkg_repo}
enabled=1
gpgcheck=0
EOF

if [ "$major_version" -eq 8 ]; then
# powertools
powertools_repo_centos="centos8-org-powertools-mirror"
cat << EOF >> /etc/yum.repos.d/artifactory-mirror.repo
[Artifactory-${powertools_repo_centos}]
name=${powertools_repo_centos}
baseurl=${ARTIFACTORY_URL}/${powertools_repo_centos}
enabled=1
gpgcheck=0
EOF
fi

if [ "$major_version" -eq 9 ]; then
  $pkg_cmd install -y lsb_release
elif [ "$major_version" -eq 8 ]; then
  $pkg_cmd install -y redhat-lsb-core
else
  echo "unsupported major_version ${major_version}"
  exit 1
fi

# install basic packages
$pkg_cmd install -y wget nfs-utils lsof vim git pciutils gdisk cloud-utils-growpart git-lfs

# install basic python3
$pkg_cmd install -y python3 python3-libs python3-devel python3-tkinter --allowerasing --skip-broken --nobest

# update os to latest. exclude kernel from getting updated
$pkg_cmd -y update --exclude=redhat-release* --exclude=kernel* --allowerasing --skip-broken --nobest

case "${major_version}.${minor_version}" in
  9.*)
    $pkg_cmd install -y \
    python3.12 \
    python3.12-devel \
    python3.12-libs \
    python3.12-pip
    alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 2
    alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 1
    alternatives --set python3 /usr/bin/python3.12
    rm -f /usr/bin/pip3
    alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.12 2
    alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.9 1
    alternatives --set pip3 /usr/bin/pip3.12
  ;;
  *)
  echo "unsupported major_version ${major_version}"
  exit 1
  ;;
esac

pip3 install --upgrade pip
pip3 install --upgrade setuptools

if [ "$minor_version" -eq 2 ]; then
  $pkg_cmd -y update --exclude=redhat-release* --exclude=kernel* --exclude=kmod-kvdo* --exclude=python3* --allowerasing --skip-broken --nobest
fi

# repo tool needs python in path
if [ ! -f /usr/bin/python ]; then
  ln -snf /usr/bin/python3 /usr/bin/python
fi

# do not change path when sudo
sed -i 's/\(Defaults.*secure_path.*\)/#\1/g' /etc/sudoers
# update grub
sed -i 's/quiet//g' /etc/default/grub
sed -i 's/splash//g' /etc/default/grub
sed -i -e 's/^GRUB_TIMEOUT=[0-9]\+$/GRUB_TIMEOUT=1/' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg