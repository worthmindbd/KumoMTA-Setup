-- =============================================================================
-- init.lua  ->  KumoMTA main policy (replaces the PowerMTA config file)
-- -----------------------------------------------------------------------------
-- This wires together the TOML data files using KumoMTA's policy helpers.
-- Deployed location: /opt/kumomta/etc/policy/init.lua
--
-- VALIDATE before relying on this in production:
--   sudo -u kumod /opt/kumomta/sbin/kumod \
--        --policy /opt/kumomta/etc/policy/init.lua --validate
--
-- Helper APIs can change between releases. If validation complains, compare
-- against the official example policy shipped with your installed version:
--   https://docs.kumomta.com/userguide/configuration/example/
-- The TOML data files (IPs, ehlo names, rates, DKIM, pool) are the stable,
-- high-value part of the migration.
-- =============================================================================

local kumo = require 'kumo'

local sources = require 'policy-extras.sources'
local dkim_sign = require 'policy-extras.dkim_sign'
local shaping = require 'policy-extras.shaping'
local listener_domains = require 'policy-extras.listener_domains'
local queue_module = require 'policy-extras.queue'

-- Load configuration from the TOML data files -------------------------------
sources:setup { '/opt/kumomta/etc/policy/sources.toml' }
local dkim_signer = dkim_sign:setup { '/opt/kumomta/etc/policy/dkim_data.toml' }
local shaper = shaping:setup { '/opt/kumomta/etc/policy/shaping.toml' }
local queue_helper = queue_module:setup { '/opt/kumomta/etc/policy/queues.toml' }

-- Startup: spool, logging, listeners ----------------------------------------
kumo.on('init', function()
  -- Spool (message store). RocksDB is the recommended backend.
  kumo.define_spool {
    name = 'data',
    path = '/var/spool/kumomta/data',
    kind = 'RocksDB',
  }
  kumo.define_spool {
    name = 'meta',
    path = '/var/spool/kumomta/meta',
    kind = 'RocksDB',
  }

  -- Structured JSON logs (replaces PowerMTA acct.csv / diag.csv).
  -- Use logrotate or max_segment_duration for rotation.
  kumo.configure_local_logs {
    log_dir = '/var/log/kumomta',
  }

  -- Port 25: inbound only -- catches OOB bounces / FBL reports.
  -- relay_hosts limited to localhost => NOT an open relay.
  kumo.start_esmtp_listener {
    listen = '0.0.0.0:25',
    hostname = 'smtp.neumannassociatesnews.io',
    relay_hosts = { '127.0.0.1', '::1' },
  }

  -- Port 587: authenticated submission from MailWizz / Listmonk (STARTTLS).
  -- NOTE: KumoMTA's ESMTP listener is built around STARTTLS. If you need
  -- implicit TLS on 465, verify support in your installed version first.
  kumo.start_esmtp_listener {
    listen = '0.0.0.0:587',
    hostname = 'smtp.neumannassociatesnews.io',
    relay_hosts = { '127.0.0.1' },
    tls_certificate = '/etc/letsencrypt/live/smtp.neumannassociatesnews.io/fullchain.pem',
    tls_private_key = '/etc/letsencrypt/live/smtp.neumannassociatesnews.io/privkey.pem',
  }

  -- HTTP injection / management API: localhost only.
  kumo.start_http_listener {
    listen = '127.0.0.1:8000',
    trusted_hosts = { '127.0.0.1', '::1' },
  }
end)

-- SMTP AUTH for submission (PowerMTA <smtp-user news@...>) -------------------
-- The password is read from the environment, NOT hardcoded here. Set
-- SMTP_NEWS_PASSWORD in the kumomta systemd unit / env file (see README).
kumo.on('smtp_server_auth_plain', function(authcred, conn_meta)
  return authcred.username == 'news@neumannassociatesnews.io'
    and authcred.password == os.getenv('SMTP_NEWS_PASSWORD')
end)

-- Inbound domain handling (relay / OOB bounce / FBL) ------------------------
kumo.on(
  'get_listener_domain',
  listener_domains:setup { '/opt/kumomta/etc/policy/listener_domains.toml' }
)

-- On every received / injected message: assign queue+pool, then DKIM sign ---
kumo.on('smtp_server_message_received', function(msg)
  queue_helper:apply(msg)
  dkim_signer(msg)
end)

kumo.on('http_message_generated', function(msg)
  queue_helper:apply(msg)
  dkim_signer(msg)
end)
