require 'etc'
require_relative '../users'
require 'minitest/autorun'

class UsersTest < Minitest::Test

  def setup
    @inst = Users.new
    @user = 'throwaway'
  end

  def teardown
    require 'open3'
    Open3.popen3("userdel -f #{@user}") do |i,o,e| end
    Open3.popen3("rm -rf /home/#{@user}") do |i,o,e| end
  end

  def test_list_users
    require 'set'

    all_users = @inst.list_users
    assert_instance_of(Set, all_users)
    all_users.each do |u|
      assert_instance_of(String, u)
    end
  end

  def test_create_user
    all_users = @inst.list_users
    assert(!all_users.find { |u| u == @user })
    success = @inst.create_user(@user, 'mypassword')
    assert(success)
    new_all_users = @inst.list_users
    diff = new_all_users - all_users
    assert_equal(@user, diff.first)
    assert_equal(1, diff.length) 
  end

end

