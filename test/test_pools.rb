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
    system "groupdel -f #{@pool} 2>/dev/null"
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
    invalid_names = ["will", "pool", "HELLO", "MY_NAME_IS", "43242342", "_myname55", "_55-4543", "_abcdefghijklmnopq-A"]
    invalid_names.each do |i|
      ex = assert_raises(RuntimeError) { @inst.create_pool(i, "password") }
      assert_equal('poolname does not fit allowable regex, aborting creation', ex.message)
    end
  end

  def test_poolname_length
    # due to test overlap, length checked first!
    invalid_names = ["_abcdefghijklmnopq-12", "abcdefghijklmnopqrstuvwxyz"]
    invalid_names.each do |i|
      ex = assert_raises(RuntimeError) { @inst.create_pool(i, "mypassword") }
      assert_equal('poolname is too long; limit is 20 characters', ex.message)
    end
  end

  def test_pool_usergroup_created_and_deleted
    require 'set'
    require 'etc'

    before_groups = Set.new
    while e = Etc.getgrent do
      before_groups << e[:name] if e[:name].match(Pools::VALID_NAME_REGEX)
    end
    Etc.endgrent

    @inst.create_pool(@pool, 'mypassword')

    after_groups = Set.new
    while e = Etc.getgrent do
      after_groups << e[:name] if e[:name].match(Pools::VALID_NAME_REGEX)
    end
    Etc.endgrent

    diff = after_groups - before_groups
    assert_equal(1, diff.length) 

    @inst.remove_pool(@pool)

    end_groups = Set.new
    while e = Etc.getgrent do
      end_groups << e[:name] if e[:name].match(Pools::VALID_NAME_REGEX)
    end
    Etc.endgrent

    assert_equal(end_groups.length, before_groups.length)
  end

  def test_create_pool_group_already_exists
    before_pools = @inst.list_pools
    assert(!before_pools.find { |u| u == @pool })
    assert !Dir.exist?(@pool_home)

    # group shouldn't exist, now create it
    system "groupadd #{@pool} 2>/dev/null"
    expected_gid = Etc.getgrnam(@pool)['gid']

    # create pool will fail because group exists
    # useradd: group _throwaway-500 exists - if you want to add this user to that group, use -g.
    success = @inst.create_pool(@pool, 'mypassword')
    assert(success)
    assert Dir.exist?(@pool_home)

    assigned_gid = Etc.getpwnam(@pool)['gid']
    assert(assigned_gid, expected_gid)

    after_pools = @inst.list_pools
    diff = after_pools - before_pools
    assert_equal(@pool, diff.first)
    assert_equal(1, diff.length)
  end

  def test_create_pool_group_already_exists
    before_pools = @inst.list_pools
    assert(!before_pools.find { |u| u == @pool })
    assert !Dir.exist?(@pool_home)

    # creating decoy regex-matched group
    system "groupadd _aa-555 2>/dev/null"
    decoy_gid = Etc.getgrnam("_aa-555")['gid']

    # real group shouldn't exist

    # creating other decoy regex-matched group
    system "groupadd _throwaway-555 2>/dev/null"
    decoy2_gid = Etc.getgrnam("_aa-555")['gid']

    success = @inst.create_pool(@pool, 'mypassword')
    assert(success)
    assert Dir.exist?(@pool_home)

    expected_gid = Etc.getgrnam(@pool)['gid']
    assigned_gid = Etc.getpwnam(@pool)['gid']
    assert(assigned_gid, expected_gid)

    after_pools = @inst.list_pools
    diff = after_pools - before_pools
    assert_equal(@pool, diff.first)
    assert_equal(1, diff.length)

    system "groupdel -f _aa-555 2>/dev/null"
    system "groupdel -f _throwaway-555 2>/dev/null"
  end
end

