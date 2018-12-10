class Pools
  VALID_NAME_REGEX = /^_[a-z]+\-[0-9]+$/

  def list_pools
    require 'set'
    require 'etc'

    candidates = Set.new
    while e = Etc.getpwent do
      candidates << e[:name] if e[:name].match(VALID_NAME_REGEX)
    end
    Etc.endpwent
    candidates
  end

  def create_pool(poolname, password)
    raise RuntimeError.new('poolname is too long; limit is 20 characters') if poolname.length > 20
    raise RuntimeError.new('poolname does not fit allowable regex, aborting creation') if !poolname.match(VALID_NAME_REGEX)
    raise RuntimeError.new('pool already exists, aborting creation') if self.list_pools.include?(poolname)
    salted_pw = password.crypt("$5$a1")
    system "useradd -U -m -p '#{salted_pw}' #{poolname} 2>/dev/null"
  end

  def remove_pool(poolname)
    raise RuntimeError.new('pool not found, aborting removal') if !self.list_pools.include?(poolname)
    system "userdel -f #{poolname} 2>/dev/null"

    require('fileutils')
    FileUtils.rm_rf "/home/#{poolname}"
  end
end
