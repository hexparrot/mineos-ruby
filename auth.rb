class Auth
  def login(username, password)
    return (username == 'mc' and password == 'password')
  end

  def login_mojang(username, password)
    require 'httparty'
    require 'json'

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
      res['user']['username']
    rescue => e
      nil
    end
  end
end
