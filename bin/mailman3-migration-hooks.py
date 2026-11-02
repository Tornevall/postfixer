"""Called by Mailman shell while Core is stopped during an explicit import."""
from mailman.interfaces.archiver import ArchivePolicy


def hold(mlist):
    mlist.emergency = True
    mlist.advertised = False
    mlist.archive_policy = ArchivePolicy.private
    mlist.send_welcome_message = False
    mlist.send_goodbye_message = False
