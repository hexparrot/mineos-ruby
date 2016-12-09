require 'airborne'

Airborne.configure do |config|
  config.base_url = 'http://localhost:4567'
end

describe 'worker list' do
  it 'should tell me which workers are responding to the queue' do
    get '/workerlist'
    expect_json_types(hosts: :array_of_strings)
    expect_status(200)
  end
end

describe 'server listing' do
  it 'should return a list of workers and each server on it' do
    get "/serverlist"
    expect_status 200
    expect_json_types(hosts: :array)
    expect_json_types(timestamp: :integer)
    expect_json_types('hosts.*', hostname: :string,
                                 servers: :array_of_strings,
                                 timestamp: :date) 
  end
end

describe 'create server on specific node' do
  require 'socket'
  WORKER_HOSTNAME=Socket.gethostname

  it 'should 201 if successfully created' do
    post "/#{WORKER_HOSTNAME}/test", {cmd: 'create'}
    expect_status 201
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)
  end
end

describe 'create server on nonexistent node' do
  it 'should 404 because it has no valid worker target' do
    post '/best/test', {cmd: 'create'}
    expect_status 404
    expect_json(server_name: 'test')
    expect_json(success: false)
    expect_json_types(success: :boolean)
  end
end

describe 'create server on any available node' do
  it 'should 201 and create the server skeleton' do
    post "/any/test", {cmd: 'create'}
    expect_status 201
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)
  end
end

describe 'bogus command on existing node' do
  it 'should 400 and do nothing' do
    post "/any/test", {cmd: 'breakdown'}
    expect_status 400
  end
end