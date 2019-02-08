require 'minitest/autorun'
require 'yaml'
require_relative '../perms'

class PermissionsTest < Minitest::Test

  def setup
  end

  def teardown
  end

  def test_create_perm
    inst = Permissions.new('plain:user')

    inst2 = Permissions.new('linux:will')
    assert_equal('linux:will', inst2.owner)
    assert(inst2.grantor?('linux:will'))
  end

  def test_load_permission_yaml
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')
    assert_instance_of(Hash, inst.permissions)

    inst.permissions.each do |k,v|
      assert_equal(Symbol, k.class)
    end
  end

  def test_load_hash
    inst = Permissions.new('plain:user')

    input = YAML::load_file('config/owner.yml')
    dump = YAML::dump(input)

    inst.load(dump)
    assert_instance_of(Hash, inst.properties)
    assert_instance_of(Hash, inst.permissions)

    inst.properties.each do |k,v|
      assert_equal(Symbol, k.class)
    end

    inst.permissions.each do |k,v|
      assert_equal(Symbol, k.class)
    end

    assert_equal('plain:user', inst.owner)
    assert_equal('linux:will', inst.properties[:grantors].first)
  end

  def test_owner
    inst = Permissions.new('plain:user')
    assert_equal('plain:user', inst.owner)
  end

  def test_dump_hash
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    input = inst.dump

    inst2 = Permissions.new('plain:user')
    inst2.load(input)

    assert_equal(inst2.properties, inst.properties)
    assert_equal(inst2.permissions, inst.permissions)
  end

  def test_check_permission
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    assert(inst.test_permission('mojang:lessertrustedadmin', :console))

    # test implicit :all
    assert(inst.test_permission('linux:will', :start))
  end

  def test_check_fake_permission
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    assert(!inst.test_permission('mojang:hexparrot', :deleteeverything))
    assert(!inst.test_permission('mojang:fraudster', :dosomethingweird))

    assert(!inst.test_permission('mojang:lessertrustedadmin', :rmrf))

    # test implicit :all
    assert(inst.test_permission('linux:will', :fakebutworks))
  end

  def test_check_permission_from_dump
    inst = Permissions.new('plain:user')
    input = YAML::load_file('config/owner.yml')
    dump = YAML::dump(input)

    inst.load(dump)

    assert(inst.test_permission('mojang:hexparrot', :start))
    assert(!inst.test_permission('mojang:fraudster', :start))

    assert(inst.test_permission('mojang:lessertrustedadmin', :console))

    # test implicit :all
    assert(inst.test_permission('linux:will', :start))
  end

  def test_get_properties
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    assert_equal('plain:user', inst.owner)
    assert_equal('linux:will', inst.grantors.first)
  end

  def test_save_yaml
    inst = Permissions.new('linux:will')
    inst.load_file('config/owner.yml')

    inst.save_file!('config/owner_new.yml')

    inst2 = Permissions.new('linux:will')
    inst2.load_file('config/owner_new.yml')

    assert_equal(inst.permissions, inst2.permissions)
    assert_equal(inst.properties, inst2.properties)
  end

  def test_save_yaml_full_ext
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    inst.save_file!('config/owner_new.yaml')

    inst2 = Permissions.new('plain:user')
    inst2.load_file('config/owner_new.yaml')

    assert_equal(inst.permissions, inst2.permissions)
    assert_equal(inst.properties, inst2.properties)
  end

  def test_save_yaml_as_nonyaml
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    ex = assert_raises(RuntimeError) { inst.save_file!('config/owner_new.txt') }
    assert_equal('cannot save YAML structure as non-yaml file', ex.message)

    ex = assert_raises(RuntimeError) { inst.save_file!('config/owner_new.txt') }
    assert_equal('cannot save YAML structure as non-yaml file', ex.message)

  end

  def test_grant
    inst = Permissions.new('plain:user')
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
    inst = Permissions.new('plain:user')
    assert(!inst.test_permission('mojang:hexparrot', :start))

    inst.grant('mojang:hexparrot', :start)
    assert(inst.test_permission('mojang:hexparrot', :start))

    inst.revoke('mojang:hexparrot', :start)
    assert(!inst.test_permission('mojang:hexparrot', :start))
  end

  def test_grantor?
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    assert(inst.grantor?('linux:will'))
    assert(!inst.grantor?('mojang:hexparrot'))
  end

  def test_make_grantor
    inst = Permissions.new('plain:user')

    assert(!inst.grantor?('linux:will'))
    assert(!inst.grantor?('mojang:hexparrot'))

    inst.make_grantor('linux:will')
    assert(inst.grantor?('linux:will'))

    inst.make_grantor('mojang:hexparrot')
    assert(inst.grantor?('linux:will'))
    assert(inst.grantor?('mojang:hexparrot'))
  end

  def test_unmake_grantor
    inst = Permissions.new('plain:user')

    assert(!inst.grantor?('mojang:hexparrot'))

    inst.make_grantor('mojang:hexparrot')
    assert(inst.grantor?('mojang:hexparrot'))

    inst.unmake_grantor('mojang:hexparrot')
    assert(!inst.grantor?('mojang:hexparrot'))
  end

  def test_owner_is_grantor_load_file
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    assert(inst.grantor?('linux:will'))
    inst.unmake_grantor('linux:will')
    assert(inst.grantor?('plain:user'))
  end

  def test_owner_is_grantor
    inst = Permissions.new('linux:will')

    assert(inst.grantor?('linux:will'))
  end

  def test_load_file_doesnt_override_provided_owner
    inst = Permissions.new('mojang:stays')
    assert_equal('mojang:stays', inst.owner)
    inst.load_file('config/owner.yml')

    assert_equal('mojang:stays', inst.owner)
  end

  def test_save_file_uses_inst_owner
    inst = Permissions.new('plain:superceding')
    inst.load_file('config/owner.yml')

    inst.save_file!('config/owner_new.yml')

    inst2 = Permissions.new('plain:user')
    inst2.load_file('config/owner_new.yml')

    assert_equal('plain:user', inst2.owner)

    inst3 = Permissions.new('plain:overruling')
    inst3.load_file('config/owner_new.yml')

    assert_equal('plain:overruling', inst3.owner)
  end

  def test_dump_hash_uses_inst_owner
    inst = Permissions.new('plain:user')
    inst.load_file('config/owner.yml')

    input = inst.dump

    inst2 = Permissions.new('mojang:myfavoriteadmin')
    inst2.load(input)

    assert_equal('mojang:myfavoriteadmin', inst2.owner)
  end

  def test_attributes
    inst = Permissions.new('plain:user')

    inst.hostname = 'myhost'
    assert_equal('myhost', inst.hostname)
    inst.workerpool = 'mypool'
    assert_equal('mypool', inst.workerpool)
    inst.servername = 'myserver'
    assert_equal('myserver', inst.servername)
  end

end
