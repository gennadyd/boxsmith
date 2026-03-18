Vagrant.configure("2") do |config|
  config.vm.box = "BOX_NAME"
  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.provider(:libvirt) { |v| v.memory = 2048; v.cpus = 2 }
end
