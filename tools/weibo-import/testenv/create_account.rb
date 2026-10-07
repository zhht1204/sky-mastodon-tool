# 一次性：在无 SMTP 的测试实例里创建本地账号（屏蔽真实发信与 MX 校验）
ActionMailer::Base.delivery_method = :test
# .test 域名无 MX 记录，仅在本次 runner 进程内跳过该校验
EmailMxValidator.class_eval { def validate(record); end }

username = ENV.fetch('IMPORTER_USERNAME', 'importer')
if Account.local.exists?(username: username)
  puts "SKIP: #{username} already exists"
else
  Account.transaction do
    account = Account.create!(username: username)
    User.create!(
      email: "#{username}@weibo-import.test",
      password: SecureRandom.hex(8),
      account: account,
      agreement: true,
      # approved 布尔列不会联动 approved_at；待审批账号的个人页会 404（check_account_approval）
      approved: true,
      approved_at: Time.current,
      confirmed_at: Time.current
    )
  end
  puts "CREATED: #{username}"
end
puts "LOCAL_ACCOUNTS=#{Account.local.count}"
