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

  def test_check_fake_permission
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')

    assert(!inst.test_permission('mojang:hexparrot', :deleteeverything))
    assert(!inst.test_permission('mojang:fraudster', :dosomethingweird))

    assert(!inst.test_permission('mojang:lessertrustedadmin', :rmrf))

    # test implicit :all
    assert(inst.test_permission('linux:will', :fakebutworks))
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

    assert_equal('linux:will', inst.get_property(:owner))
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

  def test_save_yaml_full_ext
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')

    inst.save_file!('config/owner_new.yaml')

    inst2 = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst2.load_file('config/owner_new.yaml')

    assert_equal(inst.permissions, inst2.permissions)
  end

  def test_save_yaml_as_nonyaml
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')

    ex = assert_raises(RuntimeError) { inst.save_file!('config/owner_new.txt') }
    assert_equal('cannot save YAML structure as non-yaml file', ex.message)

    ex = assert_raises(RuntimeError) { inst.save_file!('config/owner_new.txt') }
    assert_equal('cannot save YAML structure as non-yaml file', ex.message)

  end

  def test_grant
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    assert(!inst.test_permission('mojang:hexparrot', :start))

    inst.grant('mojang:hexparrot', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    inst.grant('mojang:trustedadmin', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(inst.test_permission('mojang:trustedadmin', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))
  end

  def test_revoke
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    assert(!inst.test_permission('mojang:hexparrot', :start))

    inst.grant('mojang:hexparrot', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))

    inst.revoke('mojang:hexparrot', :start)
    assert(!inst.test_permission('mojang:hexparrot', :start))
  end

  def test_grantor?
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')

    assert(inst.grantor?('linux:will'))
    assert(!inst.grantor?('mojang:hexparrot'))
  end

  def test_make_grantor
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')

    assert(!inst.grantor?('linux:will'))
    assert(!inst.grantor?('mojang:hexparrot'))

    inst.make_grantor('linux:will')
    assert(inst.grantor?('linux:will'))

    inst.make_grantor('mojang:hexparrot')
    assert(inst.grantor?('linux:will'))
    assert(inst.grantor?('mojang:hexparrot'))
  end

  def test_unmake_grantor
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')

    assert(!inst.grantor?('mojang:hexparrot'))

    inst.make_grantor('mojang:hexparrot')
    assert(inst.grantor?('mojang:hexparrot'))

    inst.unmake_grantor('mojang:hexparrot')
    assert(!inst.grantor?('mojang:hexparrot'))
  end

  def test_owner_is_grantor
    inst = Permissions.new('test', '_throwaway-500@ruby-hq')
    inst.load_file('config/owner.yml')

    assert(inst.grantor?('linux:will'))
    inst.unmake_grantor('linux:will')
    assert(inst.grantor?('linux:will'))
  end

end
