using FolderSync.Core.Interfaces;

namespace FolderSync.App.Services;

public class AuthenticationService : IAuthenticationService
{
    private readonly FolderSync.Core.Interfaces.ISecureStorage _secureStorage;
    private const string PinKey = "App_PIN";

    public AuthenticationService(FolderSync.Core.Interfaces.ISecureStorage secureStorage)
    {
        _secureStorage = secureStorage;
    }

    public async Task<bool> IsAuthenticationEnabledAsync()
    {
        var pin = await _secureStorage.GetAsync(PinKey);
        return !string.IsNullOrEmpty(pin);
    }

    public async Task SetPinAsync(string pin)
    {
        if (string.IsNullOrWhiteSpace(pin)) throw new ArgumentException("PIN cannot be empty");
        await _secureStorage.SetAsync(PinKey, pin);
    }

    public async Task<bool> VerifyPinAsync(string pin)
    {
        var storedPin = await _secureStorage.GetAsync(PinKey);
        return storedPin == pin;
    }

    public async Task RemovePinAsync()
    {
        _secureStorage.Remove(PinKey);
    }
}
