What Signserver 7.1.x requires (and why)

Java 17 runtime and WildFly 32 app server are required for SignServer 7.x. The docs explicitly call these out for 7.1.0/7.1.1. 
docs.keyfactor.com
+1

If you use PKCS#11 crypto tokens on Java 17, add this JVM export:
--add-exports=jdk.crypto.cryptoki/sun.security.pkcs11.wrapper=ALL-UNNAMED. 
docs.keyfactor.com

You can run with NoDB, but for production a DB is recommended; docs list MariaDB/MySQL/PostgreSQL/Oracle/SQL Server as supported. We’ll use MariaDB (recommended in prereqs) to avoid extra repos on OL8.10. 
docs.keyfactor.com

WildFly hardening bits and datasource creation are done with JBoss CLI; the docs include ready-to-use commands and also recommend removing RESTEasy-Crypto to avoid BouncyCastle clashes. 
docs.keyfactor.com

Deploy SignServer using the binary ZIP and bin/ant deploy (from the SignServer distro) after setting APPSRV_HOME and SIGNSERVER_NODEID, plus conf/signserver_deploy.properties. 
docs.keyfactor.com

Release artifacts for 7.1.1 are at the GitHub release page; use signserver-ce-7.1.1-bin.zip (prebuilt binaries). 
GitHub