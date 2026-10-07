# 一次性核验：实例版本与 importer 账号状态
a = Account.find_by(username: 'importer')
puts "account=#{a.acct} domain=#{a.domain.inspect} confirmed=#{a.user.confirmed?} statuses=#{a.statuses_count} last_status_at=#{a.last_status_at.inspect}"
puts "mastodon_version=#{Mastodon::Version.to_s}"
puts "local_domain=#{Setting.local_domain} reserved? actor=#{Account.representative.acct.inspect}"
