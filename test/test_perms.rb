require 'minitest/autorun'
require 'yaml'
require_relative '../perms'

class PermissionsTest < Minitest::Test

  def setup
  end

  def teardown
  end

  def test_create_perm
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    assert_equal('test', inst.name)
    assert_equal('_throwaway-500@ruby-hq', inst.pool)
  end

  def test_load_permission_yaml
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')
    assert_instance_of(Hash, inst.permissions)

    inst.permissions.each do |k,v|
      assert_equal(Symbol, k.class)
    end
  end

  def test_load_hash
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')

    input = YAML::load_file('config/owner.yml')['permissions']
    dump = YAML::dump(input)

    inst.load(dump)
    assert_instance_of(Hash, inst.permissions)

    inst.permissions.each do |k,v|
      assert_equal(Symbol, k.class)
    end
  end

  def test_check_permission
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')

    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    assert(inst.test_permission('mojang:lessertrustedadmin', :console))

    # test implicit :all
    assert(inst.test_permission('linux:will', :start))
  end

  def test_check_permission_from_dump
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    input = YAML::load_file('config/owner.yml')['permissions']
    dump = YAML::dump(input)

    inst.load(dump)

    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    assert(inst.test_permission('mojang:lessertrustedadmin', :console))

    # test implicit :all
    assert(inst.test_permission('linux:will', :start))
  end

  def test_get_property
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')

    assert_equal('linux:will', inst.get_property(:creator))
    assert_equal('test', inst.get_property(:name))
    assert_equal('user', inst.get_property(:pool))
    assert_equal('ruby-worker', inst.get_property(:host))
  end

  def test_save_yaml
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')

    inst.save_file!('config/owner_new.yml')

    inst2 = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst2.load_file('config/owner_new.yml')

    assert_equal(inst.permissions, inst2.permissions)
  end

  def test_grant
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    assert(!inst.test_permission('mojang:hexparrot', :start))

    inst.grant('mojang:hexparrot', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    inst.grant('mojang:trustedadmin', :start)
    assert(inst.test_permission('mojang:trustedadmin', :start))
  end

  def test_revoke
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    assert(!inst.test_permission('mojang:hexparrot', :start))

    inst.grant('mojang:hexparrot', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))

    inst.revoke('mojang:hexparrot', :start)
    assert(!inst.test_permission('mojang:hexparrot', :start))
  end
end
