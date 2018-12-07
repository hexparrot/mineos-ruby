require_relative '../users'
require 'minitest/autorun'

class UsersTest < Minitest::Test

  def setup
    @inst = Users.new
    @user = 'throwaway'
  end

  def teardown
    system "userdel -f #{@user} 2>/dev/null"
    system "rm -rf /home/#{@user} 2>/dev/null"
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
    before_users = @inst.list_users
    assert(!before_users.find { |u| u == @user })
    success = @inst.create_user(@user, 'mypassword')
    assert(success)
    after_users = @inst.list_users
    diff = after_users - before_users
    assert_equal(@user, diff.first)
    assert_equal(1, diff.length) 
  end

  def test_remove_user
    @inst.create_user(@user, 'mypassword')
    before_users = @inst.list_users
    assert(before_users.include?(@user))

    @inst.remove_user(@user)
    after_users = @inst.list_users
    assert(!after_users.include?(@user))

    diff = before_users - after_users
    assert_equal(@user, diff.first)
    assert_equal(1, diff.length) 
  end
end

