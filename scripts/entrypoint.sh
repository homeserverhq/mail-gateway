#!/bin/bash

# Cleanup/remove amavis pidfile
rm -f /run/amavis/amavisd.pid 2> /dev/null > /dev/null

# Only on container creation
INITIALIZED="/.initialized"
if [ ! -f "$INITIALIZED" ]; then

  SSL_CERT_FILENAME=cert.pem
  if [ ! -z ${LETS_ENCRYPT_CERT_FILENAME+x} ]; then
    SSL_CERT_FILENAME=$LETS_ENCRYPT_CERT_FILENAME
  fi
  SSL_KEY_FILENAME=key.pem
  if [ ! -z ${LETS_ENCRYPT_KEY_FILENAME+x} ]; then
    SSL_KEY_FILENAME=$LETS_ENCRYPT_KEY_FILENAME
  fi

  if [ -z ${MAIL_FQDN+x} ] || \
     [ -z ${POSTMASTER_ADDRESS+x} ] || \
     [ ! -f /etc/postfix/tls/$SSL_CERT_FILENAME ] || \
     [ ! -f /etc/postfix/tls/$SSL_KEY_FILENAME ]; then
    echo "Missing required environment variables or certificates, exiting..."
    exit 1
  fi

  MAIL_FQDN=$(echo "$MAIL_FQDN" | sed 's/[^.0-9a-z\-]//g')
  MAIL_NAME=$(echo "$MAIL_FQDN" | cut -d'.' -f1)
  MAILDOMAIN=$(echo "$MAIL_FQDN" | cut -d'.' -f2-)

  echo "Setting mail host to: $MAIL_FQDN"
  sed -i '12a\$myhostname = "'"$MAIL_FQDN"'";\' etc/amavis/conf.d/05-node_id
  echo "$MAIL_FQDN" > /etc/mailname
  echo "$MAIL_NAME" > /etc/hostname

  QUEUE_LIFETIME_BOUNCE=5d
  QUEUE_LIFETIME_MAX=5d

  if [ ! -z ${POSTFIX_QUEUE_LIFETIME_BOUNCE+x} ]; then
    echo "POSTFIX set bounce_queue_lifetime = $POSTFIX_QUEUE_LIFETIME_BOUNCE"
    QUEUE_LIFETIME_BOUNCE=$POSTFIX_QUEUE_LIFETIME_BOUNCE
  fi

  if [ ! -z ${POSTFIX_QUEUE_LIFETIME_MAX+x} ]; then
    echo "POSTFIX set maximal_queue_lifetime = $POSTFIX_QUEUE_LIFETIME_MAX"
    QUEUE_LIFETIME_MAX=$POSTFIX_QUEUE_LIFETIME_MAX
  fi

  if [ ! -f /etc/postfix/config/transport ]; then
    echo "Transport map is empty, no emails will be relayed. Creating empty file..."
    touch /etc/postfix/config/transport
  fi
  postmap /etc/postfix/config/transport

  if [ ! -f /etc/postfix/config/relay ]; then
    echo "No relay domains are specified, no emails will be relayed. Creating empty file..."
    touch /etc/postfix/config/relay
  fi
  postmap /etc/postfix/config/relay

  if [ -z ${ABUSE_ADDRESS+x} ]; then
    ABUSE_ADDRESS=$POSTMASTER_ADDRESS
  fi

  # Must have postmaster and abuse accounts enabled to be RFC compliant
  cat <<EOF >  /etc/postfix/virtual
postmaster    $POSTMASTER_ADDRESS
abuse    $ABUSE_ADDRESS
EOF
  postmap /etc/postfix/virtual

  if [ ! -f /etc/postfix/config/header_checks ]; then
    echo "No header checks file. Creating empty file..."
    touch /etc/postfix/config/header_checks
  fi

  if [ ! -f /etc/postfix/config/sasl_passwd ]; then
    echo "No forward relay hosts credentials file. Creating empty file..."
    touch /etc/postfix/config/sasl_passwd
  fi
  postmap /etc/postfix/config/sasl_passwd

  dh1024_file=/etc/postfix/dh1024.pem
  dh512_file=/etc/postfix/dh512.pem

  if [ -f /etc/postfix/tls/dh1024.pem ]; then
    dh1024_file=/etc/postfix/tls/dh1024.pem
  fi

  if [ -f /etc/postfix/tls/dh512.pem ]; then
    dh512_file=/etc/postfix/tls/dh512.pem
  fi

  if [ ! -f /etc/postfix/sasl/smtpd.conf ]; then
    cat <<EOF > /etc/postfix/sasl/smtpd.conf
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN
sasldb_path: /etc/postfix/sasl/sasldb2
EOF
  fi

  if [ ! -f /etc/postfix/sasl/sasldb2 ]; then
    tmppw=$(openssl rand -hex 32)
    echo $tmppw | saslpasswd2 -c -p -f /etc/postfix/sasl/sasldb2 tempuser
    saslpasswd2 -d -f /etc/postfix/sasl/sasldb2 tempuser
    chown postfix:sasl /etc/postfix/sasl/sasldb2
  fi

  cat <<EOF > /etc/postfix/main-new.cf
###### Host Settings ######

smtpd_banner = $MAIL_FQDN ESMTP
myhostname = $MAIL_FQDN

###### General Settings ######

biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 2
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = all
mydestination = 
relayhost = 
mynetworks = 
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
local_recipient_maps = 
local_transport = error:local mail delivery is disabled
transport_maps = hash:/etc/postfix/config/transport
relay_domains = hash:/etc/postfix/config/relay
virtual_alias_maps = hash:/etc/postfix/virtual
smtpd_helo_required = yes
bounce_queue_lifetime = $QUEUE_LIFETIME_BOUNCE
maximal_queue_lifetime = $QUEUE_LIFETIME_MAX

###### Restrictions ######

smtpd_helo_restrictions = 
    reject_invalid_helo_hostname,
    reject_non_fqdn_helo_hostname,
    reject_unknown_helo_hostname

smtpd_sender_restrictions = 
    reject_non_fqdn_sender,
    reject_unlisted_sender,
    reject_unauth_destination,
    reject_unknown_sender_domain,
    reject_unauth_pipelining

EOF

if [ -z ${DISABLE_STRICT_SPF+x} ]; then
  cat <<EOF >> /etc/postfix/main-new.cf
policyd-spf_time_limit = 3600

smtpd_recipient_restrictions = 
    reject_unauth_destination,
    reject_unknown_sender_domain,
    reject_unauth_pipelining,
    check_policy_service unix:private/policyd-spf

EOF
else
  cat <<EOF >> /etc/postfix/main-new.cf
smtpd_recipient_restrictions = 
    reject_unauth_destination,
    reject_unknown_sender_domain,
    reject_unauth_pipelining

EOF
fi

cat <<EOF >> /etc/postfix/main-new.cf
smtpd_relay_restrictions = 
    reject_unauth_destination

##### Outgoing Relay Settings #####

smtp_sasl_auth_enable = yes
smtp_sasl_security_options = noanonymous
smtp_sasl_password_maps = hash:/etc/postfix/config/sasl_passwd

##### TLS Settings ######

# Outgoing Connections #

smtp_tls_security_level = may
smtp_tls_cert_file = /etc/postfix/tls/$SSL_CERT_FILENAME
smtp_tls_key_file = /etc/postfix/tls/$SSL_KEY_FILENAME
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_exclude_ciphers = aNULL, DES, RC4, MD5, 3DES
smtp_tls_mandatory_exclude_ciphers = aNULL, DES, RC4, MD5, 3DES
smtp_tls_mandatory_ciphers = high
smtp_tls_protocols = TLSv1.3, TLSv1.2, !TLSv1.1, !TLSv1, !SSLv2, !SSLv3
smtp_tls_mandatory_protocols = TLSv1.3, TLSv1.2, !TLSv1.1, !TLSv1, !SSLv2, !SSLv3
smtp_tls_fingerprint_digest = sha256
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache
smtp_tls_loglevel = 1

# Incoming Connections #

smtpd_tls_security_level=may
smtpd_tls_cert_file = /etc/postfix/tls/$SSL_CERT_FILENAME
smtpd_tls_key_file = /etc/postfix/tls/$SSL_KEY_FILENAME
smtpd_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtpd_tls_exclude_ciphers = aNULL, DES, RC4, MD5, 3DES
smtpd_tls_mandatory_exclude_ciphers = aNULL, DES, RC4, MD5, 3DES
smtpd_tls_mandatory_ciphers = high
smtpd_tls_protocols = TLSv1.3, TLSv1.2, !TLSv1.1, !TLSv1, !SSLv2, !SSLv3
smtpd_tls_mandatory_protocols = TLSv1.3, TLSv1.2, !TLSv1.1, !TLSv1, !SSLv2, !SSLv3
smtpd_tls_fingerprint_digest = sha256
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtpd_tls_loglevel = 1
smtpd_tls_dh1024_param_file = $dh1024_file
smtpd_tls_dh512_param_file = $dh512_file

EOF

  cp /etc/postfix/master.cf /etc/postfix/master-new.cf
  cat <<EOF >> /etc/postfix/master-new.cf

submission inet n - n - - smtpd
 -o syslog_name=postfix/submission
 -o smtpd_tls_security_level=encrypt
 -o smtpd_tls_auth_only=yes
 -o smtpd_tls_req_ccert=yes
 -o smtpd_reject_unlisted_recipient=yes
 -o smtpd_client_restrictions=
 -o smtpd_helo_restrictions=
 -o smtpd_sender_restrictions=reject_sender_login_mismatch
 -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
 -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
 -o milter_macro_daemon_name=ORIGINATING
 -o cleanup_service_name=submissioncleanup
 -o smtpd_tls_CAfile=/etc/postfix/tls/$INTERNAL_CA_CERT_FILENAME
 -o smtpd_sasl_auth_enable=yes
 -o smtpd_sasl_security_options=noanonymous
 -o cyrus_sasl_config_path=/etc/postfix/sasl
 -o smtpd_sasl_local_domain=mail-gateway
 -o smtpd_sender_login_maps=hash:/etc/postfix/config/sasl_senders
 -o content_filter=
EOF

  # Performs header checks for submission emails in separate cleanup process
  cat <<EOF >> /etc/postfix/master-new.cf
submissioncleanup unix n - - - 0 cleanup
 -o header_checks=regexp:/etc/postfix/config/header_checks
 -o mime_header_checks=regexp:/etc/postfix/config/header_checks
EOF

  # Performs SPF checks
  cat <<EOF >> /etc/postfix/master-new.cf
policyd-spf unix - n n - 0 spawn
    user=policyd-spf argv=/usr/bin/policyd-spf
EOF

  if [ ! -f /etc/postfix/config/sasl_senders ]; then
    touch /etc/postfix/config/sasl_senders
  fi
  postmap /etc/postfix/config/sasl_senders

  if [ -z ${DISABLE_AMAVIS+x} ]; then
    echo "AMAVIS - enabling spam/virus scanning"

    cat <<EOF >> /etc/postfix/main-new.cf
### Amavis ###
content_filter = smtp-amavis:[127.0.0.1]:10024
receive_override_options = no_address_mappings
EOF

    cat <<EOF >> /etc/postfix/master-new.cf
smtp-amavis  unix    -    -    n    -    2    smtp
 -o smtp_data_done_timeout=1200
 -o smtp_send_xforward_command=yes
 -o disable_dns_lookups=yes

127.0.0.1:10025 inet    n    -    n    -    -    smtpd
 -o content_filter=
 -o local_recipient_maps=
 -o relay_recipient_maps=
 -o smtpd_restriction_classes=
 -o smtpd_helo_restrictions=
 -o smtpd_sender_restrictions=
 -o smtpd_recipient_restrictions=permit_mynetworks,reject
 -o smtpd_relay_restrictions=permit_mynetworks,reject_unauth_destination
 -o mynetworks=127.0.0.0/8
 -o strict_rfc821_envelopes=yes
 -o smtpd_error_sleep_time=0
 -o smtpd_soft_error_limit=1001
 -o smtpd_hard_error_limit=1000
 -o receive_override_options=no_header_body_checks
 -o smtp_tls_security_level=none
EOF

    echo 'use strict;' > /etc/amavis/conf.d/15-content_filter_mode

    if [ -z ${DISABLE_VIRUS_CHECKS+x} ]; then
     echo '@bypass_virus_checks_maps = (' >> /etc/amavis/conf.d/15-content_filter_mode
     echo '    \%bypass_virus_checks, \@bypass_virus_checks_acl, \$bypass_virus_checks_re);' >> /etc/amavis/conf.d/15-content_filter_mode
    fi

    if [ -z ${DISABLE_SPAM_CHECKS+x} ]; then
     echo '@bypass_spam_checks_maps = (' >> /etc/amavis/conf.d/15-content_filter_mode
     echo '    \%bypass_spam_checks, \@bypass_spam_checks_acl, \$bypass_spam_checks_re);' >> /etc/amavis/conf.d/15-content_filter_mode
    fi

    echo '1;  # ensure a defined return' >> /etc/amavis/conf.d/15-content_filter_mode
    echo "AMAVIS - modify settings"

    if [ -z ${AMAVIS_SA_TAG_LEVEL_DEFLT+x} ]; then
      AMAVIS_SA_TAG_LEVEL_DEFLT="undef"
    fi

    if [ -z ${AMAVIS_SA_TAG2_LEVEL_DEFLT+x} ]; then
      AMAVIS_SA_TAG2_LEVEL_DEFLT="5"
    fi

    if [ -z ${AMAVIS_SA_KILL_LEVEL_DEFLT+x} ]; then
      AMAVIS_SA_KILL_LEVEL_DEFLT="20"
    fi

    echo "    sa_tag_level_deflt  = $AMAVIS_SA_TAG_LEVEL_DEFLT;"
    echo "    sa_tag2_level_deflt  = $AMAVIS_SA_TAG2_LEVEL_DEFLT;"
    echo "    sa_kill_level_deflt  = $AMAVIS_SA_KILL_LEVEL_DEFLT;"

    sed -i -e 's/sa_tag_level_deflt.*/sa_tag_level_deflt = '"$AMAVIS_SA_TAG_LEVEL_DEFLT"';/g' /etc/amavis/conf.d/20-debian_defaults
    sed -i -e 's/sa_tag2_level_deflt.*/sa_tag2_level_deflt = '"$AMAVIS_SA_TAG2_LEVEL_DEFLT"';/g' /etc/amavis/conf.d/20-debian_defaults
    sed -i -e 's/sa_kill_level_deflt.*/sa_kill_level_deflt = '"$AMAVIS_SA_KILL_LEVEL_DEFLT"';/g' /etc/amavis/conf.d/20-debian_defaults
  fi

  # POSTFIX RAW Config ENVs
  if env | grep '^POSTFIX_RAW_CONFIG_'
  then
    echo -e "\n## POSTFIX_RAW_CONFIG ##\n" >> /etc/postfix/main-new.cf
    env | grep '^POSTFIX_RAW_CONFIG_' | while read I_CONF
    do
      CONFD_CONF_NAME=$(echo "$I_CONF" | cut -d'=' -f1 | sed 's/POSTFIX_RAW_CONFIG_//g' | tr '[:upper:]' '[:lower:]')
      CONFD_CONF_VALUE=$(echo "$I_CONF" | sed 's/^[^=]*=//g')
      echo "$CONFD_CONF_NAME""=""$CONFD_CONF_VALUE" >> /etc/postfix/main-new.cf
    done
  fi

  # Replace main.cf and master.cf
  mv /etc/postfix/main-new.cf /etc/postfix/main.cf
  mv /etc/postfix/master-new.cf /etc/postfix/master.cf

  touch "$INITIALIZED"

  # RUNIT
  echo "RUNIT - enable services"
  ln -s /container/config/runit/postfix /etc/service/postfix
  ln -s /container/config/runit/rsyslog /etc/service/rsyslog

  if [ ! -z ${DKIM_VERIFICATION+x} ]; then
    ln -s /container/config/runit/opendkim /etc/service/opendkim
  fi

  if [ -z ${DISABLE_AMAVIS+x} ]; then
    ln -s /container/config/runit/amavis /etc/service/amavis
    if [ -z ${DISABLE_VIRUS_CHECKS+x} ]; then
      ln -s /container/config/runit/clamd /etc/service/clamd
      ln -s /container/config/runit/freshclam /etc/service/freshclam
    fi
  fi

fi

rm -rf /tmp/tls 2> /dev/null
cp -a /etc/postfix/tls /tmp/tls

# CMD
echo "CMD: exec docker CMD"
echo "$@"
exec "$@"
