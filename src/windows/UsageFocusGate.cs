using System;
using System.Collections.Generic;
using System.Net;

namespace CodexHalo
{
    internal sealed class UsageFocusLease
    {
        internal AgentKind Provider;
        internal long Generation;
    }

    /// <summary>
    /// Process-wide authority for OAuth network requests and credential writes.
    /// Focus changes invalidate old leases, abort registered requests, and hold
    /// the same lock used by credential persistence so no old provider can
    /// write after the focus transition completes.
    /// </summary>
    internal static class UsageFocusGate
    {
        private static readonly object Gate = new object();
        private static readonly Dictionary<HttpWebRequest, UsageFocusLease> Requests =
            new Dictionary<HttpWebRequest, UsageFocusLease>();
        private static AgentKind activeProvider;
        private static long generation;
        private static bool hasActiveProvider;

        internal static void Activate(AgentKind provider)
        {
            List<HttpWebRequest> requests;
            lock (Gate)
            {
                if (hasActiveProvider && activeProvider == provider)
                {
                    return;
                }
                activeProvider = provider;
                hasActiveProvider = true;
                generation += 1;
                requests = new List<HttpWebRequest>(Requests.Keys);
                Requests.Clear();
            }
            AbortAll(requests);
        }

        internal static void DeactivateAll()
        {
            List<HttpWebRequest> requests;
            lock (Gate)
            {
                hasActiveProvider = false;
                generation += 1;
                requests = new List<HttpWebRequest>(Requests.Keys);
                Requests.Clear();
            }
            AbortAll(requests);
        }

        internal static bool TryAcquire(
            AgentKind provider, out UsageFocusLease lease)
        {
            lock (Gate)
            {
                if (!hasActiveProvider || activeProvider != provider)
                {
                    lease = null;
                    return false;
                }
                lease = new UsageFocusLease
                {
                    Provider = provider,
                    Generation = generation
                };
                return true;
            }
        }

        internal static bool IsCurrent(UsageFocusLease lease)
        {
            lock (Gate)
            {
                return IsCurrentLocked(lease);
            }
        }

        internal static void ThrowIfInactive(UsageFocusLease lease)
        {
            if (!IsCurrent(lease))
            {
                throw new OperationCanceledException(
                    "usage provider is no longer focused");
            }
        }

        internal static T RunCredentialWrite<T>(
            UsageFocusLease lease, Func<T> operation)
        {
            lock (Gate)
            {
                if (!IsCurrentLocked(lease))
                {
                    throw new OperationCanceledException(
                        "usage provider is no longer focused");
                }
                return operation();
            }
        }

        internal static bool RegisterRequest(
            UsageFocusLease lease, HttpWebRequest request)
        {
            bool current;
            lock (Gate)
            {
                current = IsCurrentLocked(lease);
                if (current)
                {
                    Requests[request] = lease;
                }
            }
            if (!current)
            {
                TryAbort(request);
            }
            return current;
        }

        internal static void UnregisterRequest(HttpWebRequest request)
        {
            lock (Gate)
            {
                Requests.Remove(request);
            }
        }

        internal static bool IsActiveProviderForTest(AgentKind provider)
        {
            lock (Gate)
            {
                return hasActiveProvider && activeProvider == provider;
            }
        }

        private static bool IsCurrentLocked(UsageFocusLease lease)
        {
            return lease != null &&
                hasActiveProvider &&
                activeProvider == lease.Provider &&
                generation == lease.Generation;
        }

        private static void AbortAll(IEnumerable<HttpWebRequest> requests)
        {
            foreach (HttpWebRequest request in requests)
            {
                TryAbort(request);
            }
        }

        private static void TryAbort(HttpWebRequest request)
        {
            try
            {
                request.Abort();
            }
            catch
            {
            }
        }
    }
}
