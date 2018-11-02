require 'airborne'
require 'socket'
WORKER_HOSTNAME=Socket.gethostname

Airborne.configure do |config|
  require 'yaml'
  mineos_config = YAML::load_file('config/secrets.yml')
  HOST = mineos_config['rabbitmq']['host']

  config.base_url = "http://#{HOST}:4567"
end

describe 'full startup sequence' do
  it 'should create a server, populate parameters, and start java' do
    post "/#{WORKER_HOSTNAME}/test", {cmd: 'create'}
    expect_status 201
    expect_json(success: true)
    expect_json_types(success: :boolean)

    post "/#{WORKER_HOSTNAME}/test", {cmd: 'modify_sc', section: 'java', attr: 'java_xmx', value: 512}
    expect_status 200
    expect_json(success: true)
    expect_json_types(success: :boolean)

    post "/#{WORKER_HOSTNAME}/test", {cmd: 'modify_sc', section: 'java', attr: 'java_xms', value: 512}
    expect_status 200
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)

    post "/#{WORKER_HOSTNAME}/test", {cmd: 'modify_sc', section: 'java', attr: 'jarfile', value: 'minecraft_server.1.8.9.jar'}
    expect_status 200
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)

    post "/#{WORKER_HOSTNAME}/test", {cmd: 'get_external_profile',
      url: 'https://launcher.mojang.com/v1/objects/b58b2ceb36e01bcd8dbf49c8fb66c55a9f0676cd/server.jar',
      group: 'mojang',
      version: '1.8.9',
      dest_filename: 'minecraft_server.1.8.9.jar'
    }

    expect_status 200
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)

    post "/#{WORKER_HOSTNAME}/test", {cmd: 'accept_eula'}
    expect_status 200
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)

    post "/#{WORKER_HOSTNAME}/test", {cmd: 'receive_profile', group: 'mojang', version: '1.8.9'}
    expect_status 200
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)

    post "/#{WORKER_HOSTNAME}/test", {cmd: 'start'}
    expect_status 200
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)

    sleep(10)
    post "/#{WORKER_HOSTNAME}/test", {cmd: 'stop'}
    expect_status 200
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)

    post "/#{WORKER_HOSTNAME}/test", {cmd: 'delete'}
    expect_status 200
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)

  end
end
