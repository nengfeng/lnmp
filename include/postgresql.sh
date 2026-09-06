#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# BLOG:  https://github.com/nengfeng/lnmp

# Execute a SQL file as the postgres user (safe for any password content).
# The temp file must live in /tmp so the postgres user can traverse the path.
# Usage: pg_exec_sql <psql_bin> <sql_file>
pg_exec_sql() {
  local psql_bin=$1 sql_file=$2
  chown postgres:postgres ${sql_file} && chmod 600 ${sql_file}
  su - postgres -c "${psql_bin} -v ON_ERROR_STOP=1 -f ${sql_file}"
  rm -f ${sql_file}
}

# Persist dbpostgrespwd into options.conf.
# Single quotes are doubled (SQL/POSIX style) so sourcing the file restores
# the original password; avoids sed replacement pitfalls (&, \, /).
# Usage: update_pg_options_conf <options.conf path>
update_pg_options_conf() {
  local opts_file=$1
  local pwd_conf="${dbpostgrespwd//\'/\'\'}"
  { grep -v "^dbpostgrespwd=" ${opts_file}; printf "dbpostgrespwd='%s'\n" "${pwd_conf}"; } > ${opts_file}.tmp && mv ${opts_file}.tmp ${opts_file}
  chmod 600 ${opts_file}
}

# Verify md5 connectivity as postgres via a temporary .pgpass.
# Usage: pg_verify_md5 <psql_bin>
pg_verify_md5() {
  local psql_bin=$1
  local pg_home=$(getent passwd postgres | awk -F: '{print $6}')
  local rc=1
  printf '127.0.0.1:5432:*:postgres:%s\n' "${dbpostgrespwd}" > ${pg_home}/.pgpass
  chown postgres:postgres ${pg_home}/.pgpass && chmod 600 ${pg_home}/.pgpass
  su - postgres -c "${psql_bin} -w -h 127.0.0.1 -U postgres -tAc 'select 1;'" > /dev/null 2>&1 && rc=0
  rm -f ${pg_home}/.pgpass
  return ${rc}
}

Install_PostgreSQL_APT() {
  # Install PostgreSQL from official APT repository
  echo "${CMSG}Installing PostgreSQL from official APT repository...${CEND}"

  # Add PostgreSQL official repository
  [[ "${OUTIP_STATE}"x == "China"x ]] && PG_REPO_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/postgresql || PG_REPO_MIRROR=https://download.postgresql.org/pub/repos/apt

  # Import GPG key into a keyring (apt-key was removed on Debian 12+/Ubuntu 22+)
  install -d /usr/share/keyrings
  if ! wget --quiet -O /usr/share/keyrings/postgresql.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc; then
    fail_msg "PostgreSQL APT GPG key"
    return 1
  fi

  # Add repository
  if [ -f /etc/apt/sources.list.d/pgdg.list ]; then
    rm -f /etc/apt/sources.list.d/pgdg.list
  fi

  PG_VER_MAJOR=$(echo ${pgsql_ver} | awk -F. '{print $1}')

  cat > /etc/apt/sources.list.d/pgdg.list << EOF
deb [signed-by=/usr/share/keyrings/postgresql.asc] ${PG_REPO_MIRROR} $(lsb_release -cs)-pgdg main
deb [signed-by=/usr/share/keyrings/postgresql.asc] ${PG_REPO_MIRROR} $(lsb_release -cs)-pgdg ${PG_VER_MAJOR} main
EOF

  if ! apt-get update -y; then
    fail_msg "PostgreSQL apt-get update"
    return 1
  fi

  # Install PostgreSQL
  if ! apt-get install -y postgresql-${PG_VER_MAJOR} postgresql-client-${PG_VER_MAJOR} postgresql-contrib-${PG_VER_MAJOR}; then
    fail_msg "PostgreSQL (APT)"
    return 1
  fi

  # Stop default PostgreSQL service
  service_action stop postgresql > /dev/null 2>&1

  # Relocate the apt-created cluster; never initdb a second empty one
  if [ "${pgsql_data_dir}" != "/var/lib/postgresql/${PG_VER_MAJOR}/main" ]; then
    mkdir -p ${pgsql_data_dir}
    if [ -d /var/lib/postgresql/${PG_VER_MAJOR}/main ]; then
      cp -a /var/lib/postgresql/${PG_VER_MAJOR}/main/. ${pgsql_data_dir}/
      chown -R postgres:postgres ${pgsql_data_dir}
    fi
    sed -i "s@^[#[:space:]]*data_directory.*@data_directory = '${pgsql_data_dir}'@" /etc/postgresql/${PG_VER_MAJOR}/main/postgresql.conf
  fi

  # Create install directory symlink
  mkdir -p ${pgsql_install_dir}
  ln -sf /usr/lib/postgresql/${PG_VER_MAJOR}/bin/* ${pgsql_install_dir}/bin/ 2>/dev/null || { mkdir -p ${pgsql_install_dir}/bin && ln -sf /usr/lib/postgresql/${PG_VER_MAJOR}/bin/* ${pgsql_install_dir}/bin/; }

  # Start PostgreSQL (default local peer auth still active) and set the
  # postgres password BEFORE switching to md5, or the password can never be set
  service_action start postgresql
  sleep 5

  local pg_pwd_sql=/tmp/.pg_pwd_$$.sql
  printf "alter user postgres with password '%s';\n" "${dbpostgrespwd//\'/\'\'}" > ${pg_pwd_sql}
  pg_exec_sql psql ${pg_pwd_sql}

  # Now enforce md5 authentication
  PG_HBA="/etc/postgresql/${PG_VER_MAJOR}/main/pg_hba.conf"
  [ -f "${pgsql_data_dir}/pg_hba.conf" ] && PG_HBA="${pgsql_data_dir}/pg_hba.conf"

  sed -i 's@^host.*@#&@g' ${PG_HBA}
  sed -i 's@^local.*@#&@g' ${PG_HBA}
  echo 'local   all             all                                     md5' >> ${PG_HBA}
  echo 'host    all             all             127.0.0.1/32            md5' >> ${PG_HBA}
  echo 'host    all             all             ::1/128                 md5' >> ${PG_HBA}

  # Update postgresql.conf - only listen on localhost for security
  PG_CONF="/etc/postgresql/${PG_VER_MAJOR}/main/postgresql.conf"
  [ -f "${pgsql_data_dir}/postgresql.conf" ] && PG_CONF="${pgsql_data_dir}/postgresql.conf"

  sed -i "s@^#listen_addresses.*@listen_addresses = '127.0.0.1'@" ${PG_CONF}
  sed -i "s@^listen_addresses.*@listen_addresses = '127.0.0.1'@" ${PG_CONF}

  service_action reload postgresql
  sleep 2

  # Verify with a real md5 connection instead of just checking the client binary
  if pg_verify_md5 psql; then
    update_pg_options_conf ${current_dir}/options.conf
    success_msg "PostgreSQL (APT)"
  else
    fail_msg "PostgreSQL (APT)"
    return 1
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

  # Set the postgres password while local trust auth is still active
  local pg_pwd_sql=/tmp/.pg_pwd_$$.sql
  printf "alter user postgres with password '%s';\n" "${dbpostgrespwd//\'/\'\'}" > ${pg_pwd_sql}
  pg_exec_sql ${pgsql_install_dir}/bin/psql ${pg_pwd_sql}

  # Now enforce md5 authentication
  sed -i 's@^host.*@#&@g' ${pgsql_data_dir}/pg_hba.conf
  sed -i 's@^local.*@#&@g' ${pgsql_data_dir}/pg_hba.conf
  echo 'local   all             all                                     md5' >> ${pgsql_data_dir}/pg_hba.conf
  echo 'host    all             all             127.0.0.1/32            md5' >> ${pgsql_data_dir}/pg_hba.conf
  echo 'host    all             all             ::1/128                 md5' >> ${pgsql_data_dir}/pg_hba.conf
  sed -i "s@^#listen_addresses.*@listen_addresses = '127.0.0.1'@" ${pgsql_data_dir}/postgresql.conf
  service_action reload postgresql
  sleep 2

  if pg_verify_md5 ${pgsql_install_dir}/bin/psql; then
    update_pg_options_conf ${current_dir}/options.conf
    success_msg "PostgreSQL (source)"
  else
    rm -rf ${pgsql_install_dir} ${pgsql_data_dir}
    fail_msg "PostgreSQL (source)"
    return 1
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
