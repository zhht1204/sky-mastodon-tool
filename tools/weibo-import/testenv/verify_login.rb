# 一次性：验证 importer 密码
u = User.find_by(email: 'importer@weibo-import.test')
puts "password_ok=#{u.valid_password?(ENV.fetch('IMPORTER_PASSWORD'))}"
