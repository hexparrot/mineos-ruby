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

describe 'create server on specific node' do
  it 'should 201 if successfully created' do
    require 'socket'
    post "/create/#{Socket.gethostname}/test"
    expect_status 201
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)
  end
end

describe 'create server on nonexistent node' do
  it 'should 404 because it has no valid worker target' do
    post '/create/best/test'
    expect_status 404
    expect_json(server_name: 'test')
    expect_json(success: false)
    expect_json_types(success: :boolean)
  end
end

describe 'create server on any available node' do
  it 'should 201 and create the server skeleton' do
    post "/create/any/test"
    expect_status 201
    expect_json(server_name: 'test')
    expect_json(success: true)
    expect_json_types(success: :boolean)
  end
end
