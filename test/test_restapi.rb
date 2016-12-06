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

describe 'create server' do
  it 'should create the server skeleton' do
    post '/create/any/test'
    expect_status 201
    expect_json(server_name: 'test')
    expect_json_types(success: :boolean)
  end
end
