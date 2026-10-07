# 一次性：重置 importer 密码（本地一次性测试实例，用后可弃）
u = User.find_by(email: 'importer@weibo-import.test')
raise 'user not found' if u.nil?
u.password = ENV.fetch('IMPORTER_PASSWORD')
u.save!
puts "PASSWORD_RESET for #{u.account.username} pending=#{u.pending?} approved_at=#{u.approved_at.inspect}"
