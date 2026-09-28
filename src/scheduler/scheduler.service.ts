import { Injectable, Logger } from '@nestjs/common';
import { Cron, CronExpression } from '@nestjs/schedule';
import { PrismaService } from '../prisma/prisma.service.js';

@Injectable()
export class SchedulerService {
  private readonly logger = new Logger(SchedulerService.name);

  constructor(private readonly prisma: PrismaService) {}

  @Cron(CronExpression.EVERY_MINUTE)
  async handleExpiredReservations() {
    try {
      await this.prisma.$executeRaw`SELECT process_all_expired_reservations();`;
    } catch (error) {
      this.logger.error('Failed to process expired reservations', error);
    }
  }
}
