module AlaveteliSandbox
  ##
  # Classic seccomp-BPF filter passed to bubblewrap via --seccomp. Blocks
  # high-risk kernel attack surface inside the sandbox (io_uring, bpf,
  # userfaultfd, perf_event_open, ptrace, kernel module/kexec/swap/keyring
  # syscalls) with EPERM while allowing normal converter execution.
  module Seccomp
    LD_W_ABS = 0x20
    JEQ_K = 0x15
    JGE_K = 0x35
    RET_K = 0x06

    SECCOMP_RET_ERRNO_EPERM = 0x00050001
    SECCOMP_RET_ALLOW = 0x7FFF0000
    X32_SYSCALL_BIT = 0x40000000

    ARCHS = {
      x86_64: {
        id: 0xC000003E,
        x32_bit: X32_SYSCALL_BIT,
        syscalls: [
          101, # ptrace
          163, # acct
          167, # swapon
          168, # swapoff
          169, # reboot
          175, # init_module
          176, # delete_module
          246, # kexec_load
          248, # add_key
          249, # request_key
          250, # keyctl
          298, # perf_event_open
          303, # name_to_handle_at
          304, # open_by_handle_at
          310, # process_vm_readv
          311, # process_vm_writev
          313, # finit_module
          320, # kexec_file_load
          321, # bpf
          323, # userfaultfd
          425, # io_uring_setup
          426, # io_uring_enter
          427  # io_uring_register
        ].freeze
      }.freeze,
      aarch64: {
        id: 0xC00000B7,
        syscalls: [
          89,  # acct
          104, # kexec_load
          105, # init_module
          106, # delete_module
          117, # ptrace
          142, # reboot
          217, # add_key
          218, # request_key
          219, # keyctl
          224, # swapon
          225, # swapoff
          241, # perf_event_open
          264, # name_to_handle_at
          265, # open_by_handle_at
          270, # process_vm_readv
          271, # process_vm_writev
          273, # finit_module
          280, # bpf
          282, # userfaultfd
          294, # kexec_file_load
          425, # io_uring_setup
          426, # io_uring_enter
          427  # io_uring_register
        ].freeze
      }.freeze
    }.freeze

    module_function

    def arch
      case RUBY_PLATFORM
      when /\Ax86_64-linux/ then :x86_64
      when /\A(?:aarch64|arm64)-linux/ then :aarch64
      end
    end

    def supported?
      !arch.nil?
    end

    # Binary sock_filter array for bwrap --seccomp, or nil on unsupported
    # architectures.
    def bpf(arch: self.arch)
      return nil unless arch && ARCHS.key?(arch)

      @bpf ||= {}
      @bpf[arch] ||= compile(ARCHS.fetch(arch))
    end

    def compile(spec)
      syscalls = spec[:syscalls]
      count = syscalls.size
      x32_bit = spec[:x32_bit]
      extra = x32_bit ? 1 : 0
      instructions = [
        [LD_W_ABS, 0, 0, 4],
        [JEQ_K, 0, count + extra + 2, spec[:id]],
        [LD_W_ABS, 0, 0, 0]
      ]
      instructions << [JGE_K, count + 1, 0, x32_bit] if x32_bit
      syscalls.each_with_index do |nr, index|
        instructions << [JEQ_K, count - index, 0, nr]
      end
      instructions << [RET_K, 0, 0, SECCOMP_RET_ALLOW]
      instructions << [RET_K, 0, 0, SECCOMP_RET_ERRNO_EPERM]
      instructions.map { |ins| ins.pack('S<CCL<') }.join.freeze
    end
  end
end
