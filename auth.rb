Login = Struct.new("Login", :authtype, :id)
User = Struct.new("User", :username, :password_hash)

class Auth
  def login_plain(username, password)
    require 'bcrypt'
    require 'yaml'

    users = []
    users_yaml = YAML::load_file('config/users.yml')
    users_yaml['users'].each { |u|
      users << Struct::User.new(u['name'], BCrypt::Password.new(u['password_hash']))
    }

    begin
      match = users.find { |u| u.username == username }
      if match.password_hash == password
        return Struct::Login.new(:plain, match.username)
      end
    rescue
      nil
    else
      nil
    end
  end

  def login_mojang(username, password)
    require 'httparty'

    begin
      uri = URI('https://authserver.mojang.com/authenticate')
      http = Net::HTTP.new(uri.host, uri.port)
      req = Net::HTTP::Post.new(uri.path)
      headers = {'Content-Type' => 'application/json'}
      body = { 'username' => username,
               'password' => password,
               'clientToken': 'mineos-ruby',
               'requestUser': true,
               agent: { name: 'Minecraft', version: 1 }
             }.to_json
      res = HTTParty.post(uri, body: body, headers: headers).parsed_response
      Struct::Login.new(:mojang, res['user']['username'])
    rescue => e
      nil
    end
  end

  def login_pam(username, password)
    require 'rpam2'

    if Rpam2.auth("mineos", username, password)
      Struct::Login.new(:pam, username)
    else
      nil
    end
  end
end

