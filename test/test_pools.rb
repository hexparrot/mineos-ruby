require_relative '../pools'
require 'minitest/autorun'

class PoolTest < Minitest::Test

  def setup
    @inst = Pools.new
    @pool = '_throwaway-500'
    @pool_home = "/home/#{@pool}"
  end

  def teardown
    system "userdel -f #{@pool} 2>/dev/null"
    system "rm -rf #{@pool_home} 2>/dev/null"
  end

  def test_list_pools
    require 'set'

    all_pools = @inst.list_pools
    assert_instance_of(Set, all_pools)
    all_pools.each do |u|
      assert_instance_of(String, u)
      assert(u.match(Pools::VALID_NAME_REGEX))
    end
  end

  def test_create_pool
    before_pools = @inst.list_pools
    assert(!before_pools.find { |u| u == @pool })
    assert !Dir.exist?(@pool_home)

    success = @inst.create_pool(@pool, 'mypassword')
    assert(success)
    assert Dir.exist?(@pool_home)

    after_pools = @inst.list_pools
    diff = after_pools - before_pools
    assert_equal(@pool, diff.first)
    assert_equal(1, diff.length) 
  end

  def test_remove_pool
    @inst.create_pool(@pool, 'mypassword')
    assert Dir.exist?(@pool_home)
    before_pools = @inst.list_pools
    assert(before_pools.include?(@pool))

    @inst.remove_pool(@pool)
    assert !Dir.exist?(@pool_home)
    after_pools = @inst.list_pools
    assert(!after_pools.include?(@pool))

    diff = before_pools - after_pools
    assert_equal(@pool, diff.first)
    assert_equal(1, diff.length) 
  end

  def test_create_duplicate_pool
    @inst.create_pool(@pool, 'mypassword')

    ex = assert_raises(RuntimeError) { @inst.create_pool(@pool, "mypassword") }
    assert_equal('pool already exists, aborting creation', ex.message)
  end

  def test_remove_invalid_pool
    @inst.create_pool(@pool, 'mypassword')

    ex = assert_raises(RuntimeError) { @inst.remove_pool("dinosaur") }
    assert_equal('pool not found, aborting removal', ex.message)
  end

  def test_limit_poolname_to_regex
    invalid_names = ["will", "pool", "HELLO", "MY_NAME_IS", "43242342", "_myname55", "_55-4543"]
    invalid_names.each do |i|
      ex = assert_raises(RuntimeError) { @inst.create_pool(i, "password") }
      assert_equal('poolname does not fit allowable regex, aborting creation', ex.message)
    end
  end
end

