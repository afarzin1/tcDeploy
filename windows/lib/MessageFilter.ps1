<#
    MessageFilter.ps1 -- registers a COM IOleMessageFilter for the calling thread.

    Why this exists (design §4.2): the XAE Shell is a single-threaded COM server
    that is busy for long stretches during a build. Without a message filter it
    answers incoming calls with RPC_E_CALL_REJECTED (0x80010001, "Call was
    rejected by callee") and the build dies at a random point. The filter tells
    COM to retry instead of giving up.

    Modelled on TcUnit-Runner's AutomationInterface.cs (archived Feb 2024).

    CoRegisterMessageFilter is only valid on an STA thread. Windows PowerShell
    5.1's console host is STA; pwsh 7 is MTA by default. Enable-TcMessageFilter
    refuses rather than silently no-opping if it finds itself on MTA.
#>

Set-StrictMode -Version Latest

if (-not ('TcWorkflow.MessageFilter' -as [type])) {
@'
using System;
using System.Runtime.InteropServices;

namespace TcWorkflow
{
    [ComImport, Guid("00000016-0000-0000-C000-000000000046"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IOleMessageFilter
    {
        [PreserveSig] int HandleInComingCall(int dwCallType, IntPtr hTaskCaller,
                                             int dwTickCount, IntPtr lpInterfaceInfo);
        [PreserveSig] int RetryRejectedCall(IntPtr hTaskCallee, int dwTickCount, int dwRejectType);
        [PreserveSig] int MessagePending(IntPtr hTaskCallee, int dwTickCount, int dwPendingType);
    }

    public class MessageFilter : IOleMessageFilter
    {
        // How long we are willing to keep retrying a rejected call before
        // concluding the shell is genuinely wedged rather than merely busy.
        private const int RetryWindowMs = 600000;   // 10 minutes

        public static void Register()
        {
            IOleMessageFilter previous = null;
            int hr = CoRegisterMessageFilter(new MessageFilter(), out previous);
            if (hr != 0) throw new COMException("CoRegisterMessageFilter failed", hr);
        }

        public static void Revoke()
        {
            IOleMessageFilter previous = null;
            CoRegisterMessageFilter(null, out previous);
        }

        // SERVERCALL_ISHANDLED -- we are not a server; accept anything inbound.
        int IOleMessageFilter.HandleInComingCall(int dwCallType, IntPtr hTaskCaller,
                                                 int dwTickCount, IntPtr lpInterfaceInfo)
        {
            return 0;
        }

        // Return value <100 = retry after that many ms. -1 = cancel the call.
        int IOleMessageFilter.RetryRejectedCall(IntPtr hTaskCallee, int dwTickCount, int dwRejectType)
        {
            const int SERVERCALL_RETRYLATER = 2;
            if (dwRejectType == SERVERCALL_RETRYLATER && dwTickCount < RetryWindowMs)
                return 99;      // busy, not dead -- come back in ~99ms
            return -1;          // rejected outright, or we have waited long enough
        }

        // PENDINGMSG_WAITDEFPROCESS -- keep pumping so the shell's own UI does
        // not deadlock while we are blocked on it.
        int IOleMessageFilter.MessagePending(IntPtr hTaskCallee, int dwTickCount, int dwPendingType)
        {
            return 2;
        }

        [DllImport("Ole32.dll")]
        private static extern int CoRegisterMessageFilter(IOleMessageFilter newFilter,
                                                          out IOleMessageFilter oldFilter);
    }
}
'@ | ForEach-Object { Add-Type -TypeDefinition $_ -ErrorAction Stop }
}

function Enable-TcMessageFilter {
    <#  Registers the filter, or throws if the thread cannot host one. #>
    $apt = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apt -ne 'STA') {
        throw ("COM message filter requires an STA thread, but this one is $apt. " +
               "Run the worker under Windows PowerShell 5.1 (STA by default), " +
               "or launch pwsh with -STA. Without this, long builds die on RPC_E_CALL_REJECTED.")
    }
    [TcWorkflow.MessageFilter]::Register()
}

function Disable-TcMessageFilter {
    try { [TcWorkflow.MessageFilter]::Revoke() } catch { }
}
