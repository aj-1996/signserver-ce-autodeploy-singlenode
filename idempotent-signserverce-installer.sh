#!/usr/bin/env bash
set -euo pipefail

# ---------- Vars ----------
WFLY_VER="32.0.0.Final"
WFLY_DIR="/opt/wildfly-${WFLY_VER}"
WFLY_LINK="/opt/wildfly"
SS_VER="7.1.1"
SS_ZIP_BIN="signserver-ce-${SS_VER}-bin.zip"
SS_URL="https://github.com/Keyfactor/signserver-ce/releases/download/v7.1.1/signserver-ce-7.1.1-bin.zip"
HEAP_MB="${HEAP_MB:-2048}"
DB_ROOT_PW="${DB_ROOT_PW:-StrongRoot!123}"
DB_NAME="signserver"
DB_USER="signserver"
DB_PW="${DB_PW:-StrongDb!123}"
NODE_ID="${NODE_ID:-node1}"

# ---------- OS prereqs ----------
dnf -y install java-17-openjdk unzip wget tar ant mariadb-server

# ---------- WildFly ----------
if [ ! -d "$WFLY_DIR" ]; then
  wget -q "wget https://download.jboss.org/wildfly/32.0.0.Final/wildfly-32.0.0.Final.zip" -O /tmp/wildfly.zip
  unzip -q /tmp/wildfly.zip -d /opt/
fi
ln -snf "$WFLY_DIR" "$WFLY_LINK"

# systemd service (from bundled contrib)
cp -f ${WFLY_LINK}/docs/contrib/scripts/systemd/launch.sh ${WFLY_LINK}/bin || true
cp -f ${WFLY_LINK}/docs/contrib/scripts/systemd/wildfly.service /etc/systemd/system || true
mkdir -p /etc/wildfly
cat >/etc/wildfly/wildfly.conf <<EOF
WILDFLY_CONFIG=standalone.xml
WILDFLY_MODE=standalone
WILDFLY_BIND=0.0.0.0
EOF
useradd -r -s /bin/false wildfly || true
chown -R wildfly:wildfly "${WFLY_DIR}"

# Bump heap & add Java17 PKCS11 export
# (edit in-place in standalone.conf; create if needed)
SC="${WFLY_LINK}/bin/standalone.conf"
if ! grep -q "JAVA_OPTS" "$SC"; then
  echo 'JAVA_OPTS="-Xms'${HEAP_MB}'m -Xmx'${HEAP_MB}'m -Djava.awt.headless=true"' >> "$SC"
fi
# Ensure heap and TLS & export for PKCS11 wrapper
sed -i \
  -e "s/-Xms[0-9]*m/-Xms${HEAP_MB}m/g" \
  -e "s/-Xmx[0-9]*m/-Xmx${HEAP_MB}m/g" \
  "$SC"
grep -q "https.protocols" "$SC" || echo 'JAVA_OPTS="$JAVA_OPTS -Dhttps.protocols=TLSv1.2,TLSv1.3 -Djdk.tls.client.protocols=TLSv1.2,TLSv1.3"' >> "$SC"
grep -q "jdk.crypto.cryptoki" "$SC" || echo 'JAVA_OPTS="$JAVA_OPTS --add-exports=jdk.crypto.cryptoki/sun.security.pkcs11.wrapper=ALL-UNNAMED"' >> "$SC"

# Remove RESTEasy-Crypto (to avoid BC conflicts)
sed -i '/org.jboss.resteasy.resteasy-crypto/d' ${WFLY_LINK}/modules/system/layers/base/org/jboss/as/jaxrs/main/module.xml || true
rm -rf ${WFLY_LINK}/modules/system/layers/base/org/jboss/resteasy/resteasy-crypto/ || true

# Make service live
systemctl daemon-reload
systemctl enable --now wildfly

# ---------- MariaDB ----------
systemctl enable --now mariadb
mysqladmin -u root password "${DB_ROOT_PW}" || true
mysql -uroot -p"${DB_ROOT_PW}" <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PW}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# Add Elytron credential store master password script
cat >/usr/bin/wildfly_pass <<'EOS'
#!/bin/sh
echo 'UseYourOwnSuperSecretMasterPass!'
EOS
chown wildfly:wildfly /usr/bin/wildfly_pass
chmod 700 /usr/bin/wildfly_pass

# Create credential store
sudo -u wildfly ${WFLY_LINK}/bin/jboss-cli.sh --connect '/subsystem=elytron/credential-store=defaultCS:add(location=keystore/credentials, relative-to=jboss.server.config.dir, credential-reference={clear-text="{EXT}/usr/bin/wildfly_pass", type="COMMAND"}, create=true)' || true

# JDBC driver (MariaDB)
wget -q https://dlm.mariadb.com/3852266/Connectors/java/connector-java-3.4.1/mariadb-java-client-3.4.1.jar -O ${WFLY_LINK}/standalone/deployments/mariadb-java-client.jar

# Datasource with password in credential store
sudo -u wildfly ${WFLY_LINK}/bin/jboss-cli.sh --connect "/subsystem=elytron/credential-store=defaultCS:add-alias(alias=dbPassword, secret-value=\"${DB_PW}\")" || true
sudo -u wildfly ${WFLY_LINK}/bin/jboss-cli.sh --connect 'data-source add --name=signserverds --connection-url="jdbc:mysql://127.0.0.1:3306/'${DB_NAME}'" --jndi-name="java:/SignServerDS" --use-ccm=true --driver-name="mariadb-java-client.jar" --driver-class="org.mariadb.jdbc.Driver" --user-name="'${DB_USER}'" --credential-reference={store=defaultCS, alias=dbPassword} --validate-on-match=true --background-validation=false --prepared-statements-cache-size=50 --share-prepared-statements=true --min-pool-size=5 --max-pool-size=150 --pool-prefill=true --transaction-isolation=TRANSACTION_READ_COMMITTED --check-valid-connection-sql="select 1;"' || true
sudo -u wildfly ${WFLY_LINK}/bin/jboss-cli.sh --connect ':reload'

# ---------- SignServer CE 7.1.1 ----------
mkdir -p /opt/signserver && cd /opt/signserver
if [ ! -d "signserver" ]; then
  wget -q "${SS_URL}" -O "/tmp/${SS_ZIP_BIN}"
  unzip -q "/tmp/${SS_ZIP_BIN}" -d /opt/signserver
fi

# Env for deploy
echo "export APPSRV_HOME=${WFLY_DIR}" >/etc/profile.d/signserver.sh
echo "export SIGNSERVER_NODEID=${NODE_ID}" >>/etc/profile.d/signserver.sh
source /etc/profile.d/signserver.sh

# Configure deployment properties
cd /opt/signserver/signserver
cp -n conf/signserver_deploy.properties.sample conf/signserver_deploy.properties
# database.name=mysql (for MariaDB); ensure default JNDI java:/SignServerDS is used
sed -i 's/^database.name=.*/database.name=mysql/' conf/signserver_deploy.properties

# Optional: NoDB example (commented)
# sed -i 's/^database.name=.*/database.name=nodb/' conf/signserver_deploy.properties
# sed -i 's|^#\?database.nodb.location=.*|database.nodb.location=/opt/signserver/nodb|' conf/signserver_deploy.properties

# Deploy
ant -q deploy

# Verify deployment file exists
ls -l ${WFLY_LINK}/standalone/deployments | grep -i signserver || true

echo "Done. Try:  http://$(hostname -I | awk '{print $1}'):8080/signserver"
echo "AdminWeb:   http://$(hostname -I | awk '{print $1}'):8080/signserver/adminweb"