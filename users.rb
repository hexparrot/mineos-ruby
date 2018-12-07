class Users

  def list_users
    require 'set'

    raw_output = `cat /etc/passwd |grep '/home' |cut -d: -f1`
    Set.new(raw_output.strip.split("\n"))
  end

  def create_user(username, password)
    salted_pw = password.crypt("$5$a1")
    system "useradd -m -p '#{salted_pw}' #{username} 2>/dev/null"
  end

  def remove_user(username)
    system "userdel -f #{username} 2>/dev/null"

    require('fileutils')
    FileUtils.rm_rf "/home/#{username}"
  end
end
