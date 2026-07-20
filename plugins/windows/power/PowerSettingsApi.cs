using System;
using System.Runtime.InteropServices;

public static class WinixPowerSettingsApi
{
    private static readonly Guid DisplaySubgroup = new("7516b95f-f776-4464-8c53-06167f40cc99");
    private static readonly Guid DisplayIdleTimeout = new("3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e");
    private static readonly Guid PresenceSubgroup = new("8619b916-e004-4dd8-9b66-dae86f806698");
    private static readonly Guid PresenceAwayDisplayTimeout = new("0a7d6ab6-ac83-4ad1-8282-eca5b58308f3");
    private static readonly Guid PresenceAwayDimTimeout = new("a79c8e0e-f271-482d-8f8a-5db9a18312de");
    private static readonly Guid PresenceInattentiveDimTimeout = new("cf8c6097-12b8-4279-bbdd-44601ee5209d");
    private static readonly Guid PresenceInattentiveDisplayTimeout = new("ee16691e-6ab3-4619-bb48-1c77c9357e5a");

    public static Guid GetActiveScheme()
    {
        IntPtr pointer;
        ThrowIfError(PowerGetActiveScheme(IntPtr.Zero, out pointer), "read the active power scheme");
        try
        {
            return Marshal.PtrToStructure<Guid>(pointer);
        }
        finally
        {
            LocalFree(pointer);
        }
    }

    public static uint ReadTimeout(Guid scheme, string settingName, bool onBattery)
    {
        GetSetting(settingName, out Guid subgroup, out Guid setting);
        uint value;
        uint result = onBattery
            ? PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value)
            : PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value);
        ThrowIfError(result, "read the display idle timeout");
        return value;
    }

    public static void WriteTimeout(Guid scheme, string settingName, bool onBattery, uint value)
    {
        GetSetting(settingName, out Guid subgroup, out Guid setting);
        uint result = onBattery
            ? PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, value)
            : PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, value);
        ThrowIfError(result, "write the display idle timeout");
    }

    public static void Activate(Guid scheme)
    {
        ThrowIfError(PowerSetActiveScheme(IntPtr.Zero, ref scheme), "reactivate the power scheme");
    }

    private static void GetSetting(string settingName, out Guid subgroup, out Guid setting)
    {
        switch (settingName)
        {
            case "display_idle":
                subgroup = DisplaySubgroup;
                setting = DisplayIdleTimeout;
                return;
            case "presence_away_display":
                subgroup = PresenceSubgroup;
                setting = PresenceAwayDisplayTimeout;
                return;
            case "presence_away_dim":
                subgroup = PresenceSubgroup;
                setting = PresenceAwayDimTimeout;
                return;
            case "presence_inattentive_dim":
                subgroup = PresenceSubgroup;
                setting = PresenceInattentiveDimTimeout;
                return;
            case "presence_inattentive_display":
                subgroup = PresenceSubgroup;
                setting = PresenceInattentiveDisplayTimeout;
                return;
            default:
                throw new ArgumentException($"Unknown Windows power setting '{settingName}'.", nameof(settingName));
        }
    }

    private static void ThrowIfError(uint result, string action)
    {
        if (result != 0)
            throw new InvalidOperationException($"Failed to {action}: Win32 error {result}.");
    }

    [DllImport("powrprof.dll")]
    private static extern uint PowerGetActiveScheme(IntPtr userRootPowerKey, out IntPtr activePolicyGuid);

    [DllImport("powrprof.dll")]
    private static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, out uint valueIndex);

    [DllImport("powrprof.dll")]
    private static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, out uint valueIndex);

    [DllImport("powrprof.dll")]
    private static extern uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, uint valueIndex);

    [DllImport("powrprof.dll")]
    private static extern uint PowerWriteDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subgroupGuid, ref Guid settingGuid, uint valueIndex);

    [DllImport("powrprof.dll")]
    private static extern uint PowerSetActiveScheme(IntPtr userRootPowerKey, ref Guid schemeGuid);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
