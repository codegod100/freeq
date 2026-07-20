# frozen_string_literal: true

# Cookie session for Rails CSRF + flash. Behind boxd TLS termination the app
# only sees HTTP, so force Secure cookies explicitly (assume_ssl alone does
# not always propagate into the session store's secure check).
Rails.application.config.session_store :cookie_store,
  key: "_freeq_web2_session",
  same_site: :lax,
  secure: !Rails.env.development?,
  expire_after: 14.days