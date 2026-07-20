using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Winix.Arp;

public static class CommandLine
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string[] Parse(string commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine))
        {
            throw new ArgumentException("The ARP uninstall command was empty.", nameof(commandLine));
        }

        IntPtr argumentVector = CommandLineToArgvW(commandLine, out int argumentCount);
        if (argumentVector == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "The ARP uninstall command could not be parsed.");
        }

        try
        {
            var arguments = new string[argumentCount];
            for (int index = 0; index < argumentCount; index++)
            {
                IntPtr argument = Marshal.ReadIntPtr(argumentVector, index * IntPtr.Size);
                arguments[index] = Marshal.PtrToStringUni(argument)
                    ?? throw new InvalidOperationException("CommandLineToArgvW returned a null argument.");
            }

            return arguments;
        }
        finally
        {
            _ = LocalFree(argumentVector);
        }
    }
}
