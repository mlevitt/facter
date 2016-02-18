require 'facter/util/windows'
require 'ffi'

module Facter::Util::Windows::Process
  extend FFI::Library

  def get_current_process
    # this pseudo-handle does not require closing per MSDN docs
    GetCurrentProcess()
  end
  module_function :get_current_process

  def open_process_token(handle, desired_access, &block)
    token_handle = nil
    begin
      FFI::MemoryPointer.new(:handle, 1) do |token_handle_ptr|
        result = OpenProcessToken(handle, desired_access, token_handle_ptr)
        if result == FFI::WIN32_FALSE
          raise Facter::Util::Windows::Error.new(
              "OpenProcessToken(#{handle}, #{desired_access.to_s(8)}, #{token_handle_ptr})")
        end

        yield token_handle = token_handle_ptr.read_handle
      end

      token_handle
    ensure
      FFI::WIN32.CloseHandle(token_handle) if token_handle
    end

    # token_handle has had CloseHandle called against it, so nothing to return
    nil
  end
  module_function :open_process_token

  def get_token_information(token_handle, token_information, &block)
    # to determine buffer size
    FFI::MemoryPointer.new(:dword, 1) do |return_length_ptr|
      result = GetTokenInformation(token_handle, token_information, nil, 0, return_length_ptr)
      return_length = return_length_ptr.read_dword

      if return_length <= 0
        raise Facter::Util::Windows::Error.new(
            "GetTokenInformation(#{token_handle}, #{token_information}, nil, 0, #{return_length_ptr})")
      end

      # re-call API with properly sized buffer for all results
      FFI::MemoryPointer.new(return_length) do |token_information_buf|
        result = GetTokenInformation(token_handle, token_information,
                                     token_information_buf, return_length, return_length_ptr)

        if result == FFI::WIN32_FALSE
          raise Facter::Util::Windows::Error.new(
              "GetTokenInformation(#{token_handle}, #{token_information}, #{token_information_buf}, " +
                  "#{return_length}, #{return_length_ptr})")
        end

        yield token_information_buf
      end
    end

    # GetTokenInformation buffer has been cleaned up by this point, nothing to return
    nil
  end
  module_function :get_token_information

  def parse_token_information_as_token_elevation(token_information_buf)
    TOKEN_ELEVATION.new(token_information_buf)
  end
  module_function :parse_token_information_as_token_elevation

  TOKEN_QUERY = 0x0008
  # Returns whether or not the owner of the current process is running
  # with elevated security privileges.
  #
  # Only supported on Windows Vista or later.
  #
  def elevated_security?
    # default / pre-Vista
    elevated = false
    handle = nil

    begin
      handle = get_current_process
      open_process_token(handle, TOKEN_QUERY) do |token_handle|
        get_token_information(token_handle, :TokenElevation) do |token_info|
          token_elevation = parse_token_information_as_token_elevation(token_info)
          # TokenIsElevated member of the TOKEN_ELEVATION struct
          elevated = token_elevation[:TokenIsElevated] != 0
        end
      end

      elevated
    rescue Facter::Util::Windows::Error => e
      raise e if e.code != ERROR_NO_SUCH_PRIVILEGE
    ensure
      FFI::WIN32.CloseHandle(handle) if handle
    end
  end
  module_function :elevated_security?

  def windows_major_version
    ver = 0

    FFI::MemoryPointer.new(OSVERSIONINFO.size) do |os_version_ptr|
      os_version = OSVERSIONINFO.new(os_version_ptr)
      os_version[:dwOSVersionInfoSize] = OSVERSIONINFO.size

      result = GetVersionExW(os_version_ptr)

      if result == FFI::WIN32_FALSE
        raise Facter::Util::Windows::Error.new("GetVersionEx failed")
      end

      ver = os_version[:dwMajorVersion]
    end

    ver
  end
  module_function :windows_major_version

  def supports_elevated_security?
    windows_major_version >= 6
  end
  module_function :supports_elevated_security?

  ffi_convention :stdcall

  # https://msdn.microsoft.com/en-us/library/windows/desktop/ms683179(v=vs.85).aspx
  # HANDLE WINAPI GetCurrentProcess(void);
  ffi_lib :kernel32
  attach_function_private :GetCurrentProcess, [], :handle

  # https://msdn.microsoft.com/en-us/library/windows/desktop/aa379295(v=vs.85).aspx
  # BOOL WINAPI OpenProcessToken(
  #   _In_   HANDLE ProcessHandle,
  #   _In_   DWORD DesiredAccess,
  #   _Out_  PHANDLE TokenHandle
  # );
  ffi_lib :advapi32
  attach_function_private :OpenProcessToken,
                          [:handle, :dword, :phandle], :win32_bool

  # https://msdn.microsoft.com/en-us/library/windows/desktop/aa379626(v=vs.85).aspx
  TOKEN_INFORMATION_CLASS = enum(
      :TokenUser, 1,
      :TokenGroups,
      :TokenPrivileges,
      :TokenOwner,
      :TokenPrimaryGroup,
      :TokenDefaultDacl,
      :TokenSource,
      :TokenType,
      :TokenImpersonationLevel,
      :TokenStatistics,
      :TokenRestrictedSids,
      :TokenSessionId,
      :TokenGroupsAndPrivileges,
      :TokenSessionReference,
      :TokenSandBoxInert,
      :TokenAuditPolicy,
      :TokenOrigin,
      :TokenElevationType,
      :TokenLinkedToken,
      :TokenElevation,
      :TokenHasRestrictions,
      :TokenAccessInformation,
      :TokenVirtualizationAllowed,
      :TokenVirtualizationEnabled,
      :TokenIntegrityLevel,
      :TokenUIAccess,
      :TokenMandatoryPolicy,
      :TokenLogonSid,
      :TokenIsAppContainer,
      :TokenCapabilities,
      :TokenAppContainerSid,
      :TokenAppContainerNumber,
      :TokenUserClaimAttributes,
      :TokenDeviceClaimAttributes,
      :TokenRestrictedUserClaimAttributes,
      :TokenRestrictedDeviceClaimAttributes,
      :TokenDeviceGroups,
      :TokenRestrictedDeviceGroups,
      :TokenSecurityAttributes,
      :TokenIsRestricted,
      :MaxTokenInfoClass
  )

  # https://msdn.microsoft.com/en-us/library/windows/desktop/bb530717(v=vs.85).aspx
  # typedef struct _TOKEN_ELEVATION {
  #   DWORD TokenIsElevated;
  # } TOKEN_ELEVATION, *PTOKEN_ELEVATION;
  class TOKEN_ELEVATION < FFI::Struct
    layout :TokenIsElevated, :dword
  end

  # https://msdn.microsoft.com/en-us/library/windows/desktop/aa446671(v=vs.85).aspx
  # BOOL WINAPI GetTokenInformation(
  #   _In_       HANDLE TokenHandle,
  #   _In_       TOKEN_INFORMATION_CLASS TokenInformationClass,
  #   _Out_opt_  LPVOID TokenInformation,
  #   _In_       DWORD TokenInformationLength,
  #   _Out_      PDWORD ReturnLength
  # );
  ffi_lib :advapi32
  attach_function_private :GetTokenInformation,
                          [:handle, TOKEN_INFORMATION_CLASS, :lpvoid, :dword, :pdword ], :win32_bool

  # https://msdn.microsoft.com/en-us/library/windows/desktop/ms724834%28v=vs.85%29.aspx
  # typedef struct _OSVERSIONINFO {
  #   DWORD dwOSVersionInfoSize;
  #   DWORD dwMajorVersion;
  #   DWORD dwMinorVersion;
  #   DWORD dwBuildNumber;
  #   DWORD dwPlatformId;
  #   TCHAR szCSDVersion[128];
  # } OSVERSIONINFO;
  class OSVERSIONINFO < FFI::Struct
    layout(
        :dwOSVersionInfoSize, :dword,
        :dwMajorVersion, :dword,
        :dwMinorVersion, :dword,
        :dwBuildNumber, :dword,
        :dwPlatformId, :dword,
        :szCSDVersion, [:wchar, 128]
    )
  end

  # https://msdn.microsoft.com/en-us/library/windows/desktop/ms724451(v=vs.85).aspx
  # BOOL WINAPI GetVersionEx(
  #   _Inout_  LPOSVERSIONINFO lpVersionInfo
  # );
  ffi_lib :kernel32
  attach_function_private :GetVersionExW,
                          [:pointer], :win32_bool
end
