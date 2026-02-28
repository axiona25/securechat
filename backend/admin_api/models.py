from django.db import models
from accounts.models import User


class AdminGroup(models.Model):
    """Gruppi organizzativi gestiti dall'admin. Determinano la visibilità tra utenti."""
    name = models.CharField(max_length=255, unique=True)
    description = models.TextField(blank=True, default="")
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    members = models.ManyToManyField(User, through='AdminGroupMembership', related_name='admin_groups', blank=True)

    class Meta:
        db_table = 'admin_groups'
        ordering = ['-created_at']

    def __str__(self):
        return self.name


class AdminGroupMembership(models.Model):
    """Appartenenza utente a un gruppo organizzativo."""
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='admin_group_memberships')
    group = models.ForeignKey(AdminGroup, on_delete=models.CASCADE, related_name='memberships')
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        db_table = 'admin_group_memberships'
        unique_together = ('user', 'group')

    def __str__(self):
        return f"{self.user.username} in {self.group.name}"
