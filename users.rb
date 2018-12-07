class Users

  def list_users
    require 'set'

    raw_output = `cat /etc/passwd |grep '/home' |cut -d: -f1`
    Set.new(raw_output.strip.split("\n"))
  end

  def create_user(username, password)
    require 'open3'
    salted_pw = password.crypt("$5$a1")
    system "useradd -m -p '#{salted_pw}' #{username} 2>/dev/null"
  end

end
