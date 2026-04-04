#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

Install_PostgreSQL_APT() {
  # Install PostgreSQL from official APT repository
  echo "${CMSG}Installing PostgreSQL from official APT repository...${CEND}"
  
  # Add PostgreSQL official repository
  [[ "${OUTIP_STATE}"x == "China"x ]] && PG_REPO_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/postgresql || PG_REPO_MIRROR=https://download.postgresql.org/pub/repos/apt
  
  # Import GPG key
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - > /dev/null 2>&1
  
  # Add repository
  if [ -f /etc/apt/sources.list.d/pgdg.list ]; then
    rm -f /etc/apt/sources.list.d/pgdg.list
  fi
  
  PG_VER_MAJOR=$(echo ${pgsql_ver} | awk -F. '{print $1}')
  
  cat > /etc/apt/sources.list.d/pgdg.list << EOF
deb ${PG_REPO_MIRROR} $(lsb_release -cs)-pgdg main
deb ${PG_REPO_MIRROR} $(lsb_release -cs)-pgdg ${PG_VER_MAJOR} main
EOF
  
  apt-get update -y > /dev/null 2>&1
  
  # Install PostgreSQL
  apt-get install -y postgresql-${PG_VER_MAJOR} postgresql-client-${PG_VER_MAJOR} postgresql-contrib-${PG_VER_MAJOR}
  
  # Stop default PostgreSQL service
  service_action stop postgresql > /dev/null 2>&1
  
  # Create data directory if different from default
  if [ "${pgsql_data_dir}" != "/var/lib/postgresql/${PG_VER_MAJOR}/main" ]; then
    mkdir -p ${pgsql_data_dir}
    chown -R postgres:postgres ${pgsql_data_dir}
    
    # Update data directory in service
    sed -i "s@/var/lib/postgresql/${PG_VER_MAJOR}/main@${pgsql_data_dir}@g" /etc/postgresql/${PG_VER_MAJOR}/main/postgresql.conf 2>/dev/null || true
  fi
  
  # Create install directory symlink
  mkdir -p ${pgsql_install_dir}
  ln -sf /usr/lib/postgresql/${PG_VER_MAJOR}/bin/* ${pgsql_install_dir}/bin/ 2>/dev/null || mkdir -p ${pgsql_install_dir}/bin && ln -sf /usr/lib/postgresql/${PG_VER_MAJOR}/bin/* ${pgsql_install_dir}/bin/
  
  # Configure PostgreSQL
  su - postgres -c "/usr/lib/postgresql/${PG_VER_MAJOR}/bin/initdb -D ${pgsql_data_dir}" 2>/dev/null || true
  
  # Update pg_hba.conf
  PG_HBA="/etc/postgresql/${PG_VER_MAJOR}/main/pg_hba.conf"
  [ -f "${pgsql_data_dir}/pg_hba.conf" ] && PG_HBA="${pgsql_data_dir}/pg_hba.conf"
  
  sed -i 's@^host.*@#&@g' ${PG_HBA}
  sed -i 's@^local.*@#&@g' ${PG_HBA}
  echo 'local   all             all                                     md5' >> ${PG_HBA}
  echo 'host    all             all             0.0.0.0/0               md5' >> ${PG_HBA}
  
  # Update postgresql.conf - only listen on localhost for security
  PG_CONF="/etc/postgresql/${PG_VER_MAJOR}/main/postgresql.conf"
  [ -f "${pgsql_data_dir}/postgresql.conf" ] && PG_CONF="${pgsql_data_dir}/postgresql.conf"
  
  sed -i "s@^#listen_addresses.*@listen_addresses = '127.0.0.1'@" ${PG_CONF}
  sed -i "s@^listen_addresses.*@listen_addresses = '127.0.0.1'@" ${PG_CONF}
  
  # Start PostgreSQL
  service_action start postgresql
  sleep 5
  
  # Set postgres password
  local pwd_escaped=$(escape_password "${dbpostgrespwd}")
  su - postgres -c "psql -c \"alter user postgres with password '$pwd_escaped';\""
  service_action reload postgresql
   
  if command -v psql &> /dev/null; then
    sed -i "s+^dbpostgrespwd.*+dbpostgrespwd='${pwd_escaped}'+" ../options.conf
    chmod 600 ../options.conf
    success_msg "PostgreSQL (APT)"
  else
    fail_msg "PostgreSQL (APT)"
  fi
}

Install_PostgreSQL_Source() {
  # Install PostgreSQL from source compilation
  echo "${CMSG}Installing PostgreSQL from source compilation...${CEND}"
  
  pushd ${current_dir}/src > /dev/null
  id -u postgres >/dev/null 2>&1
  [ $? -ne 0 ] && useradd -d ${pgsql_install_dir} -s /bin/bash postgres
  mkdir -p ${pgsql_data_dir};chown postgres.postgres -R ${pgsql_data_dir}
  tar xzf postgresql-${pgsql_ver}.tar.gz
  pushd postgresql-${pgsql_ver}
  ./configure --prefix=$pgsql_install_dir --with-openssl --with-libxml --with-libxslt --with-uuid=e2fs --with-readline --with-zlib
  compile_and_install
  chmod 755 ${pgsql_install_dir}
  chown -R postgres.postgres ${pgsql_install_dir}
  /bin/cp ${current_dir}/systemd/postgresql.service /lib/systemd/system/
  sed -i "s@=/usr/local/pgsql@=${pgsql_install_dir}@g" /lib/systemd/system/postgresql.service
  sed -i "s@PGDATA=.*@PGDATA=${pgsql_data_dir}@" /lib/systemd/system/postgresql.service
  service_action enable postgresql
  popd
  su - postgres -c "${pgsql_install_dir}/bin/initdb -D ${pgsql_data_dir}"
  service_action start postgresql
  sleep 5
  local pwd_escaped=$(escape_password "${dbpostgrespwd}")
  su - postgres -c "${pgsql_install_dir}/bin/psql -c \"alter user postgres with password '$pwd_escaped';\""
  sed -i 's@^host.*@#&@g' ${pgsql_data_dir}/pg_hba.conf
  sed -i 's@^local.*@#&@g' ${pgsql_data_dir}/pg_hba.conf
  echo 'local   all             all                                     md5' >> ${pgsql_data_dir}/pg_hba.conf
  echo 'host    all             all             127.0.0.1/0            md5' >> ${pgsql_data_dir}/pg_hba.conf
  sed -i "s@^#listen_addresses.*@listen_addresses = '127.0.0.1'@" ${pgsql_data_dir}/postgresql.conf
  service_action reload postgresql

  if [ -e "${pgsql_install_dir}/bin/psql" ]; then
    sed -i "s+^dbpostgrespwd.*+dbpostgrespwd='${pwd_escaped}'+" ../options.conf
    chmod 600 ../options.conf
    success_msg "PostgreSQL (source)"
  else
    rm -rf ${pgsql_install_dir} ${pgsql_data_dir}
    fail_msg "PostgreSQL (source)"
  fi
  popd
  [ -z "$(grep ^'export PATH=' /etc/profile)" ] && echo "export PATH=${pgsql_install_dir}/bin:\$PATH" >> /etc/profile
  [[ -n "$(grep ^'export PATH=' /etc/profile)" && -z "$(grep ${pgsql_install_dir} /etc/profile)" ]] && sed -i "s@^export PATH=\(.*\)@export PATH=${pgsql_install_dir}/bin:\1@" /etc/profile
  refresh_path
}

Install_PostgreSQL() {
  if [[ "${pgsqlinstallmethod}" == "1" ]]; then
    Install_PostgreSQL_APT
  elif [[ "${pgsqlinstallmethod}" == "2" ]]; then
    Install_PostgreSQL_Source
  fi
}