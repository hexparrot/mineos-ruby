class Users
  VALID_NAME_REGEX = /^_[a-z]+\-[0-9]+$/

  def list_users
    require 'set'

    raw_output = `cat /etc/passwd |grep '/home' |cut -d: -f1`
    candidates = Set.new(raw_output.strip.split("\n"))
    candidates.delete_if { |e| !e.match(VALID_NAME_REGEX) }
  end

  def create_user(username, password)
    raise RuntimeError.new('username does not fit allowable regex, aborting creation') if !username.match(VALID_NAME_REGEX)
    raise RuntimeError.new('user already exists, aborting creation') if self.list_users.include?(username)
    salted_pw = password.crypt("$5$a1")
    system "useradd -m -p '#{salted_pw}' #{username} 2>/dev/null"
  end

  def remove_user(username)
    raise RuntimeError.new('user not found, aborting removal') if !self.list_users.include?(username)
    system "userdel -f #{username} 2>/dev/null"

    require('fileutils')
    FileUtils.rm_rf "/home/#{username}"
  end
end
