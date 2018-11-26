Login = Struct.new("Login", :authtype, :id)

class Auth
  def login_plain(username, password)
    require 'bcrypt'
    require 'yaml'
    
    users = YAML::load_file('config/users.yml')

    # https://gist.github.com/tomdalling/b873e731e5c6c56431807d40a904f6cf
    def hash_password(password)
      BCrypt::Password.create(password).to_s
    end

    match = users['users'].find { |u| u['name'] == username }

    begin
      if (match['name'] == username and match['password'] == password) then
        return Struct::Login.new(:plain, username)
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

