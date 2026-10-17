/// Off the web there is no browser dialog to open. The visit sheet is still
/// readable on screen, so this reports that printing is unavailable instead of
/// offering a button that would do nothing.
bool get canPrint => false;

void printPage() {}
