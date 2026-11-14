#!/usr/bin/env bash
# Read-only: print ONLY non-secret Supabase Auth settings (sign-in, OTP, MFA, rate limits). Never prints keys or passwords.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env.supabase; set +a
curl -sS "https://api.supabase.com/v1/projects/hvnsgwfcjpakvhhkfsuy/config/auth" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" | jq '{disable_signup, external_email_enabled, external_phone_enabled, mailer_otp_exp, mailer_otp_length, mailer_secure_email_change_enabled, mfa_totp_enroll_enabled, mfa_totp_verify_enabled, mfa_max_enrolled_factors, jwt_exp, sessions_timebox, sessions_inactivity_timeout, refresh_token_rotation_enabled, security_refresh_token_reuse_interval, rate_limit_email_sent, rate_limit_otp, rate_limit_verify, rate_limit_token_refresh, security_captcha_enabled, security_captcha_provider, password_min_length, site_url}'
